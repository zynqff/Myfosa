#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LLAMA="$ROOT/.build/llama.cpp"
REPO="https://github.com/chaxu01/llama.cpp.git"
COMMIT="92c448af6"

# ВАЖНО: перед rm -rf на .build/llama.cpp явно уходим в $ROOT.
# Если вызывающий скрипт (например, шаг в codemagic.yaml) уже стоит
# внутри .build/llama.cpp, rm -rf удаляет текущую директорию шелла,
# и следующая же команда (git clone) падает с
# "fatal: Unable to read current working directory" — это баг
# порядка команд, а не прав доступа/сети.
cd "$ROOT"

rm -rf "$LLAMA"
mkdir -p "$ROOT/.build"
git clone --filter=blob:none "$REPO" "$LLAMA"
cd "$LLAMA"
git checkout --detach "$COMMIT"
python3 - "$LLAMA" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
metal=root/'ggml/src/ggml-metal/ggml-metal.metal'
device=root/'ggml/src/ggml-metal/ggml-metal-device.cpp'
ops=root/'ggml/src/ggml-metal/ggml-metal-ops.cpp'
s=metal.read_text()
if 'kernel_mul_mv_q2_0c_f32' in s: raise SystemExit('Q2_0C Metal patch already present')
# Exact CPU mapping: uint2 0,1,2,3 -> -3,-1,+1,+3; one fp16 scale per 512 values.
needle='template <typename type4x4>\nvoid dequantize_q2_0(device const block_q2_0 * xb, short il, thread type4x4 & reg) {'
idx=s.index(needle)
q2c='''template <typename type4x4>\nvoid dequantize_q2_0c(device const block_q2_0c * xb, short il, thread type4x4 & reg) {\n    device const uint8_t * qs = xb->qs;\n    const float d = xb->d;\n    const int byte_offset = il * 4;\n    float4x4 reg_f;\n    for (int i = 0; i < 4; ++i) {\n        const uint8_t b = qs[byte_offset + i];\n        reg_f[i][0] = (float(2 * int((b >> 0) & 3) - 3)) * d;\n        reg_f[i][1] = (float(2 * int((b >> 2) & 3) - 3)) * d;\n        reg_f[i][2] = (float(2 * int((b >> 4) & 3) - 3)) * d;\n        reg_f[i][3] = (float(2 * int((b >> 6) & 3) - 3)) * d;\n    }\n    reg = (type4x4) reg_f;\n}\n\n'''
s=s[:idx]+q2c+s[idx:]
# Native GEMV kernel: 512-element blocks, no conversion.
marker='[[host_name("kernel_mul_mv_q2_0_f32")]]'
idx=s.index(marker)
gemv='''template<short NR0, typename args_t>\nvoid kernel_mul_mv_q2_0c_f32_impl(args_t args, device const char * src0, device const char * src1, device char * dst, uint3 tgpig, ushort tiisg, ushort sgitg) {\n    constexpr int QK = QKQ2_0C;\n    constexpr int BYTES = QK / 4;\n    const int nb = args.ne00 / QK;\n    const int r0 = (tgpig.x * FC_mul_mv_nsg + sgitg) * NR0;\n    const int r1 = tgpig.y;\n    const int im = tgpig.z;\n    const uint i12 = im % FC_mul_mv_ne12;\n    const uint i13 = im / FC_mul_mv_ne12;\n    const uint64_t off1 = r1*args.nb11 + i12*args.nb12 + i13*args.nb13;\n    device const float * y = (device const float *)(src1 + off1);\n    device const block_q2_0c * a[NR0];\n    for (int row=0; row<NR0; ++row) {\n        const uint64_t off0=(r0+row)*args.nb01+(i12/FC_mul_mv_r2)*args.nb02+(i13/FC_mul_mv_r3)*args.nb03;\n        a[row]=(device const block_q2_0c *)(src0+off0);\n    }\n    float sum[NR0]={0.0f};\n    const int lane_base=tiisg*16;\n    for (int ib=0; ib<nb; ++ib) {\n        const device float * yy=y+ib*QK+lane_base;\n        const device uint8_t * q=a[0][ib].qs;\n        for (int j=0;j<16;j++) {\n            const int k=lane_base+j;\n            const uint8_t b=q[k/4];\n            const int code=(b>>(2*(k&3)))&3;\n            const float v=float(2*code-3)*float(a[0][ib].d);\n            const float xv=yy[j];\n            sum[0]+=v*xv;\n        }\n        for (int row=1; row<NR0; ++row) {\n            const device uint8_t * qr=a[row][ib].qs;\n            const float d=float(a[row][ib].d);\n            for (int j=0;j<16;j++) { int k=lane_base+j; int code=(qr[k/4]>>(2*(k&3)))&3; sum[row]+=float(2*code-3)*d*yy[j]; }\n        }\n    }\n    device float * out=(device float*)dst+(uint64_t)im*args.ne0*args.ne1+(uint64_t)r1*args.ne0;\n    for (int row=0;row<NR0;row++) { const float v=simd_sum(sum[row]); if (tiisg==0 && r0+row<args.ne01) out[r0+row]=v; }\n}\n[[host_name("kernel_mul_mv_q2_0c_f32")]]\nkernel void kernel_mul_mv_q2_0c_f32(constant ggml_metal_kargs_mul_mv & args, device const char * src0, device const char * src1, device char * dst, uint3 tgpig[[threadgroup_position_in_grid]], ushort tiisg[[thread_index_in_simdgroup]], ushort sgitg[[simdgroup_index_in_threadgroup]]) {\n    kernel_mul_mv_q2_0c_f32_impl<N_R0_Q2_0, constant ggml_metal_kargs_mul_mv &>(args,src0,src1,dst,tgpig,tiisg,sgitg);\n}\n\n'''
s=s[:idx]+gemv+s[idx:]
# Direct native GEMM for Q2_0C. This is correctness-first and handles arbitrary MxN; it does not repack.
gemm='''[[host_name("kernel_mul_mm_q2_0c_f32")]]\nkernel void kernel_mul_mm_q2_0c_f32(constant ggml_metal_kargs_mul_mm & args, device const char * src0, device const char * src1, device char * dst, uint3 gid[[thread_position_in_grid]]) {\n    const int n=gid.x, m=gid.y, im=gid.z;\n    if (n>=args.ne0 || m>=args.ne1) return;\n    const int i12=im % args.ne12;\n    const int i13=im / args.ne12;\n    const int a2=i12/args.r2, a3=i13/args.r3;\n    const device block_q2_0c * a=(const device block_q2_0c *)(src0 + n*args.nb01 + a2*args.nb02 + a3*args.nb03);\n    const device float * b=(const device float *)(src1 + m*args.nb11 + i12*args.nb12 + i13*args.nb13);\n    float acc=0.0f;\n    const int nb=args.ne00/QKQ2_0C;\n    for (int ib=0;ib<nb;++ib) {\n        const float d=float(a[ib].d);\n        for (int j=0;j<QKQ2_0C;++j) { const uint8_t q=a[ib].qs[j>>2]; const int code=(q>>(2*(j&3)))&3; acc+=float(2*code-3)*d*b[ib*QKQ2_0C+j]; }\n    }\n    ((device float *)dst + i13*args.ne1*args.ne0*args.ne12 + i12*args.ne1*args.ne0)[m*args.ne0+n]=acc;\n}\n\n'''
s=s[:idx]+gemm+s[idx:]
# register q2c matrix kernels in existing templated MM section is intentionally NOT used; custom kernel is dispatched directly.
metal.write_text(s)
# device pipeline: GEMV selector and MM remains custom in ops.
s=device.read_text()
needle='        case GGML_TYPE_Q2_0:\n            {\n                nsg = N_SG_Q2_0;\n                nr0 = N_R0_Q2_0;\n            } break;'
assert needle in s
s=s.replace(needle,needle+'\n        case GGML_TYPE_Q2_0C:\n            {\n                nsg = N_SG_Q2_0;\n                nr0 = N_R0_Q2_0;\n            } break;',1)
# Also allow Q2_0C in MUL_MAT_ID matrix-vector pipeline selector by replacing second Q2_0 occurrence after function start.
pos=s.index('ggml_metal_pipeline_with_params ggml_metal_library_get_pipeline_mul_mv_id')
tail=s[pos:]
assert needle in tail
tail=tail.replace(needle,needle+'\n        case GGML_TYPE_Q2_0C:\n            {\n                nsg = N_SG_Q2_0;\n                nr0 = N_R0_Q2_0;\n            } break;',1)
s=s[:pos]+tail
device.write_text(s)
# ops: route Q2_0C to custom GEMM before normal matrix-mm branch.
s=ops.read_text()
needle='    } else if (\n        !ggml_is_transposed(op->src[0]) &&\n'
assert needle in s
branch='''    } else if (op->src[0]->type == GGML_TYPE_Q2_0C && op->src[1]->type == GGML_TYPE_F32 &&\n               !ggml_is_transposed(op->src[0]) && !ggml_is_transposed(op->src[1])) {\n        auto pipeline = ggml_metal_library_compile_pipeline(lib,\n            "kernel_mul_mm_q2_0c_f32", "kernel_mul_mm_q2_0c_f32", nullptr);\n        ggml_metal_kargs_mul_mm args = {\n            ne00, ne02, nb01, nb02, nb03, (int16_t)ne12,\n            nb10, nb11, nb12, nb13, ne0, ne1, r2, r3\n        };\n        ggml_metal_encoder_set_pipeline(enc, pipeline);\n        ggml_metal_encoder_set_bytes(enc, &args, sizeof(args), 0);\n        ggml_metal_encoder_set_buffer(enc, ggml_metal_get_buffer_id(op->src[0]), 1);\n        ggml_metal_encoder_set_buffer(enc, ggml_metal_get_buffer_id(op->src[1]), 2);\n        ggml_metal_encoder_set_buffer(enc, ggml_metal_get_buffer_id(op), 3);\n        ggml_metal_encoder_dispatch_threadgroups(enc, ne01, ne11, ne12*ne13, 1, 1, 1);\n'''
s=s.replace(needle,branch+needle,1)
# Ensure Q2_0C is eligible for the initial small-batch path; otherwise the custom GEMM handles it.
s=s.replace('            op->src[0]->type == GGML_TYPE_Q2_0 ||\n','            op->src[0]->type == GGML_TYPE_Q2_0 ||\n            op->src[0]->type == GGML_TYPE_Q2_0C ||\n',1)
ops.write_text(s)
print('Applied native Q2_0C Metal GEMV + direct GEMM patch')
PY
