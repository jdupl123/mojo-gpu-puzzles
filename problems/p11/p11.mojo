from gpu import thread_idx, block_idx, block_dim, barrier
from gpu.host import DeviceContext
from layout import Layout, LayoutTensor
from layout.tensor_builder import LayoutTensorBuild as tb
from sys import sizeof, argv
from testing import assert_equal

# ANCHOR: conv_1d_simple
alias TPB = 8
alias SIZE = 6
alias CONV = 3
alias BLOCKS_PER_GRID = (1, 1)
alias THREADS_PER_BLOCK = (TPB, 1)
alias dtype = DType.float32
alias in_layout = Layout.row_major(SIZE)
alias out_layout = Layout.row_major(SIZE)
alias conv_layout = Layout.row_major(CONV)


fn conv_1d_simple[
    in_layout: Layout, out_layout: Layout, conv_layout: Layout
](
    out: LayoutTensor[mut=False, dtype, out_layout],
    a: LayoutTensor[mut=False, dtype, in_layout],
    b: LayoutTensor[mut=False, dtype, in_layout],
):
    global_i = block_dim.x * block_idx.x + thread_idx.x
    local_i = thread_idx.x
    if global_i >= SIZE: return
    data = tb[dtype]().row_major[SIZE]().shared().alloc()
    kernel = tb[dtype]().row_major[CONV]().shared().alloc()
    if local_i<SIZE: data[local_i] = a[local_i]
    if local_i<CONV: kernel[local_i] = b[local_i]
    barrier()
    
    # out = sum_j(a[i+j] * b[j])
    @parameter
    tmp = data[local_i+0] * kernel[0]
    for j in range(1,CONV):
        if local_i + j < SIZE: 
            tmp += data[local_i+j] * kernel[j]
    out[local_i]=tmp




# ANCHOR_END: conv_1d_simple

# ANCHOR: conv_1d_block_boundary
alias SIZE_2 = 15
alias CONV_2 = 4
alias BLOCKS_PER_GRID_2 = (2, 1)
alias THREADS_PER_BLOCK_2 = (TPB, 1)


fn conv_1d_block_boundary[
    in_layout: Layout, out_layout: Layout, conv_layout: Layout, dtype: DType
](
    out: LayoutTensor[mut=False, dtype, out_layout],
    a: LayoutTensor[mut=False, dtype, in_layout],
    b: LayoutTensor[mut=False, dtype, in_layout],
):
    global_i = block_dim.x * block_idx.x + thread_idx.x
    local_i = thread_idx.x
    if global_i >= SIZE_2: return
    data = tb[dtype]().row_major[TPB+CONV_2-1]().shared().alloc()
    kernel = tb[dtype]().row_major[CONV_2]().shared().alloc()

    if local_i<TPB: data[local_i] = a[global_i]
    if local_i<CONV_2: kernel[local_i] = b[local_i]
    if local_i==TPB-1:
        for j in range(1,CONV_2):
            if global_i + j < SIZE_2:
                data[local_i+j] = a[global_i+j]
    barrier()
    
    # out = sum_j(a[i+j] * b[j])
    @parameter
    tmp = data[local_i] * kernel[0]
    for j in range(1,CONV_2):
        tmp += data[local_i+j] * kernel[j]
    out[global_i]=tmp


# ANCHOR_END: conv_1d_block_boundary


def main():
    with DeviceContext() as ctx:
        size = SIZE_2 if argv()[1] == "--block-boundary" else SIZE
        conv = CONV_2 if argv()[1] == "--block-boundary" else CONV
        out = ctx.enqueue_create_buffer[dtype](size).enqueue_fill(0)
        a = ctx.enqueue_create_buffer[dtype](size).enqueue_fill(0)
        b = ctx.enqueue_create_buffer[dtype](conv).enqueue_fill(0)
        with a.map_to_host() as a_host:
            for i in range(size):
                a_host[i] = i

        with b.map_to_host() as b_host:
            for i in range(conv):
                b_host[i] = i

        out_tensor = LayoutTensor[mut=False, dtype, out_layout](
            out.unsafe_ptr()
        )
        a_tensor = LayoutTensor[mut=False, dtype, in_layout](a.unsafe_ptr())
        b_tensor = LayoutTensor[mut=False, dtype, in_layout](b.unsafe_ptr())

        if argv()[1] == "--simple":
            ctx.enqueue_function[
                conv_1d_simple[in_layout, out_layout, conv_layout]
            ](
                out_tensor,
                a_tensor,
                b_tensor,
                size,
                conv,
                grid_dim=BLOCKS_PER_GRID,
                block_dim=THREADS_PER_BLOCK,
            )
        elif argv()[1] == "--block-boundary":
            ctx.enqueue_function[
                conv_1d_block_boundary[
                    in_layout, out_layout, conv_layout, dtype
                ]
            ](
                out_tensor,
                a_tensor,
                b_tensor,
                size,
                conv,
                grid_dim=BLOCKS_PER_GRID_2,
                block_dim=THREADS_PER_BLOCK_2,
            )
        else:
            raise Error("Invalid argument")

        expected = ctx.enqueue_create_host_buffer[dtype](size).enqueue_fill(0)
        ctx.synchronize()

        with a.map_to_host() as a_host, b.map_to_host() as b_host:
            for i in range(size):
                for j in range(conv):
                    if i + j < size:
                        expected[i] += a_host[i + j] * b_host[j]

        with out.map_to_host() as out_host:
            print("out:", out_host)
            print("expected:", expected)
            for i in range(size):
                for j in range(conv):
                    if i + j < size:
                        assert_equal(out_host[i], expected[i])
