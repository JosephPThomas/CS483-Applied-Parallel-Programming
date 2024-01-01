#include <cmath>
#include <iostream>
#include "gpu-new-forward.h"
#define TILE_WIDTH 8
__global__ void conv_forward_kernel(float *output, const float *input, const float *mask, const int B, const int M, const int C, const int H, const int W, const int K,const int S)
{
    /*
    Modify this function to implement the forward pass described in Chapter 16.
    We have added an additional dimension to the tensors to support an entire mini-batch
    The goal here is to be correct AND fast.

    Function paramter definitions:
    output - output
    input - input
    mask - convolution kernel
    B - batch_size (number of images in x)
    M - number of output feature maps
    C - number of input feature maps
    H - input height dimension
    W - input width dimension
    K - kernel height and width (K x K)
    S - stride step length
    */
    extern __shared__ float sum[];
    const int H_out = (H - K)/S + 1;
    const int W_out = (W - K)/S + 1;
    //(void)H_out; // silence declared but never referenced warning. remove this line when you start working
    //(void)W_out; // silence declared but never referenced warning. remove this line when you start working

    // We have some nice #defs for you below to simplify indexing. Feel free to use them, or create your own.
    // An example use of these macros:
    // float a = in_4d(0,0,0,0)
    // out_4d(0,0,0,0) = a

    #define out_4d(i3, i2, i1, i0) output[(i3) * (M * H_out * W_out) + (i2) * (H_out * W_out) + (i1) * (W_out) + i0]
    #define in_4d(i3, i2, i1, i0) input[(i3) * (C * H * W) + (i2) * (H * W) + (i1) * (W) + i0]
    #define mask_4d(i3, i2, i1, i0) mask[(i3) * (C * K * K) + (i2) * (K * K) + (i1) * (K) + i0]
    #define tree_3d(i2, i1, i0) sum[(i2) * TILE_WIDTH * C + (i1) * C + i0]

    // Insert your GPU convolution kernel code here
    int W_grid = ceil(W_out / (1.0*TILE_WIDTH));
    int ty = threadIdx.y;
    int tx = threadIdx.x;
    int tz = threadIdx.z;
    int n = blockIdx.x;
    int b = blockIdx.z;
    int h = (blockIdx.y / W_grid) * TILE_WIDTH + ty;
    int w = (blockIdx.y % W_grid) * TILE_WIDTH + tx;

    if (h < H_out && w < W_out) {
        float acc = 0.0;
        for (int p = 0; p < K; p++)
            for (int q = 0; q < K; q++)
                acc += in_4d(b, tz, h * S + p, w * S + q) * mask_4d(n, tz, p, q);
        tree_3d(ty, tx, tz) = acc;

        for (int stride = ceil(1.0*C/2); stride >= 1; stride >>= 1) {
            __syncthreads();
            if (tz < stride && tz + stride < C)  
                tree_3d(ty, tx, tz) += tree_3d(ty, tx, tz + stride);
        }
        __syncthreads();
        if (tz == 0)  out_4d(b, n, h, w) = tree_3d(ty, tx, tz);
    }

    #undef out_4d
    #undef in_4d
    #undef mask_4d
    #undef tree_3d
}
	
__host__ void GPUInterface::conv_forward_gpu_prolog(const float *host_output, const float *host_input, const float *host_mask, float **device_output_ptr, float **device_input_ptr, float **device_mask_ptr, const int B, const int M, const int C, const int H, const int W, const int K, const int S)
{
    // Allocate memory and copy over the relevant data structures to the GPU
    const int H_out = (H - K)/S + 1;
    const int W_out = (W - K)/S + 1;

    int output_size = (H_out * W_out * M * B * sizeof(float)); 
    int input_size = (H * W * C * B * sizeof(float)); 
    int k_size = (K * K * M * C * sizeof(float));

    cudaMalloc((void**)device_input_ptr, input_size);
    cudaMalloc((void**)device_mask_ptr, k_size);
    cudaMalloc((void**)device_output_ptr, output_size);
    

    cudaMemcpy(*device_input_ptr, host_input, input_size, cudaMemcpyHostToDevice);
    cudaMemcpy(*device_mask_ptr, host_mask, k_size, cudaMemcpyHostToDevice);

    // We pass double pointers for you to initialize the relevant device pointers,
    //  which are passed to the other two functions.

    // Useful snippet for error checking
    // cudaError_t error = cudaGetLastError();
    // if(error != cudaSuccess)
    // {
    //     std::cout<<"CUDA error: "<<cudaGetErrorString(error)<<std::endl;
    //     exit(-1);
    // }
   
}


__host__ void GPUInterface::conv_forward_gpu(float *device_output, const float *device_input, const float *device_mask, const int B, const int M, const int C, const int H, const int W, const int K, const int S)
{
    // Set the kernel dimensions and call the kernel
        const int H_out = (H - K)/S + 1;
        const int W_out = (W - K)/S + 1;
        int H_grid = ceil(H_out / (1.0*TILE_WIDTH));
        int W_grid = ceil(W_out / (1.0*TILE_WIDTH));
        dim3 dimGrid(M, H_grid * W_grid, B);
        dim3 dimBlock(TILE_WIDTH, TILE_WIDTH, C);
        size_t sum_size = C * TILE_WIDTH * TILE_WIDTH * sizeof(float);
        conv_forward_kernel<<<dimGrid, dimBlock, sum_size>>>(device_output, device_input, device_mask, B, M, C, H, W, K, S);
}


__host__ void GPUInterface::conv_forward_gpu_epilog(float *host_output, float *device_output, float *device_input, float *device_mask, const int B, const int M, const int C, const int H, const int W, const int K, const int S)
{
    const int H_out = (H - K)/S + 1;
    const int W_out = (W - K)/S + 1;

    int output_size = (H_out*W_out) * M * B * sizeof(float);
    // Copy the output back to host
    cudaMemcpy(host_output, device_output, output_size, cudaMemcpyDeviceToHost);
   
    // Free device memory
    
    cudaFree(device_output);
    cudaFree(device_input);
    cudaFree(device_mask);
}


__host__ void GPUInterface::get_device_properties()
{
    int deviceCount;
    cudaGetDeviceCount(&deviceCount);

    for(int dev = 0; dev < deviceCount; dev++)
    {
        cudaDeviceProp deviceProp;
        cudaGetDeviceProperties(&deviceProp, dev);

        std::cout<<"Device "<<dev<<" name: "<<deviceProp.name<<std::endl;
        std::cout<<"Computational capabilities: "<<deviceProp.major<<"."<<deviceProp.minor<<std::endl;
        std::cout<<"Max Global memory size: "<<deviceProp.totalGlobalMem<<std::endl;
        std::cout<<"Max Constant memory size: "<<deviceProp.totalConstMem<<std::endl;
        std::cout<<"Max Shared memory size per block: "<<deviceProp.sharedMemPerBlock<<std::endl;
        std::cout<<"Max threads per block: "<<deviceProp.maxThreadsPerBlock<<std::endl;
        std::cout<<"Max block dimensions: "<<deviceProp.maxThreadsDim[0]<<" x, "<<deviceProp.maxThreadsDim[1]<<" y, "<<deviceProp.maxThreadsDim[2]<<" z"<<std::endl;
        std::cout<<"Max grid dimensions: "<<deviceProp.maxGridSize[0]<<" x, "<<deviceProp.maxGridSize[1]<<" y, "<<deviceProp.maxGridSize[2]<<" z"<<std::endl;
        std::cout<<"Warp Size: "<<deviceProp.warpSize<<std::endl;
    }
}
