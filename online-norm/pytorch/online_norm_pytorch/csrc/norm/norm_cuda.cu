/* 
 * Released under BSD 3-Clause License,
 * Copyright (c) 2019 Cerebras Systems Inc.
 * All rights reserved.
 *
 * Define norm fwd / bwd cpp functions and cuda kernels
 *
 * Author:  Vitaliy Chiley
 * Contact: {vitaliy, info}@cerebras.net
 */

#include "norm.h"

#include <torch/extension.h>

#include <vector>

#include <ATen/ATen.h>
#include <ATen/cuda/CUDAContext.h>

#include <THC/THC.h>
#include <THC/THCAtomics.cuh>
#include <THC/THCDeviceUtils.cuh>

#include <stdio.h>


#define Idx3(n, c, d, N, C, D) (((n)*(C)*(D)) + ((c)*(D)) + (d))
#define Idx2(n, c, N, C) (((n)*(C)) + (c))

#define CHECK_CUDA(x) AT_ASSERTM(x.type().is_cuda(), #x " must be a CUDA tensor")
#define CHECK_CONTIGUOUS(x) AT_ASSERTM(x.is_contiguous(), #x " must be contiguous")
#define CHECK_INPUT(x) CHECK_CUDA(x); CHECK_CONTIGUOUS(x)


/* 
 * shared mem reduction within a warp
 */
__device__ void warp_reduce(
    volatile float *s_mem,
    const unsigned int t_id,
    const unsigned int d) {
  for (unsigned int ridx = 32; ridx > 0; ridx /= 2) {
    if (d > ridx) {
      if ((t_id < ridx) && ((t_id + ridx) < d)) {
        s_mem[t_id] += s_mem[t_id + ridx];
      }
      __syncwarp();
    }
  }
}

/* 
 * OnlineNorm forward kernel implementation
 * The ON fwd algorithm is:
 *
 *    scale = sqrt(s_var + eps)
 *    out = (input - s_mu) / scale
 *    mu, var = moments(input)
 *    diff = mu - s_mu
 *    s_var = afwd * s_var + (1 - afwd) * var + afwd * (1 - afwd) * diff * diff
 *    s_mu = s_mu + (1 - afwd) * diff
 *
 * where out is the output of ON, scale is the std. dev. used to scale the data
 * in the fwd pass and is cached for the bwd pass, eps is used for numerical
 * stability, s_mu and s_var are the streaming mean and variance,
 * mu and var are the sample mean and variance of the input, diff is an
 * intermediate stored variable, and afwd is the forward decay factor.
 *
 * The ON algorithm loops over N samples. s_mem_mu and s_mem_var are
 * shared memory used in the reduction (reduction over D) needed to update
 * s_mu and s_var. Each thread block operates on an one of C features
 * (ie. channel when operating on spatial data). Each channel has a s_mu and
 * s_var streaming statistics which are updated per sample by the reductions
 * per thread block.
 *
 * The kernel assumes contiguous inputs inputs of shape (N, C, *) where D is
 * the product of *.
 */
template <typename scalar_t>
__global__ void norm_fwd_kernel(
    const scalar_t* __restrict__ input,
    float* s_mu,
    float* s_var,
    scalar_t* __restrict__ scale,
    scalar_t* __restrict__ out,
    const unsigned int C, const unsigned int N, const unsigned int D,
    const float afwd, const float eps) {

  const unsigned int t_id = threadIdx.x;
  const unsigned int c = blockIdx.x;
  const unsigned int d = blockDim.x;
  unsigned int idx3, idx;

  extern __shared__ float s_mem_mu[];
  float *s_mem_var = &s_mem_mu[d];

  float in_elem_f, sample_mu, sample_var, diff;
  scalar_t in_elem, m, s;

  for(int n = 0; n < N; ++n){
    s_mem_mu[t_id] = 0;                             // reset sample mu shared mem
    s_mem_var[t_id] = 0;                            // reset sample var shared mem
    // propagate fwd activations and start reduction to compute input mu and var
    m = (scalar_t)(s_mu[c]);
    s = (scalar_t)(sqrt(s_var[c] + eps));

    if (t_id == 0) { scale[Idx2(n, c, N, C)] = s; } // store scale used

    for (idx = t_id; idx < D; idx += d) {
      idx3 = Idx3(n, c, idx, N, C, D);              // idx in global mem
      in_elem = input[idx3];                        // get input element
      out[idx3] = (in_elem - m) / s;                // compute output
    
      // start 1st and 2nd moment reductions
      in_elem_f = (float)(in_elem);
      s_mem_mu[t_id] += in_elem_f;                  // 1st moment reduction
      s_mem_var[t_id] += in_elem_f * in_elem_f;     // 2nd moment reduction
    }
    __syncthreads();

    // reduce within thread block % warp reduction
    for (idx = 512; idx > 32; idx /= 2) {
      if (d > idx) {
        if ((t_id < idx) && ((t_id + idx) < d)) {
          s_mem_mu[t_id] += s_mem_mu[t_id + idx];   // 1st moment reduction
          s_mem_var[t_id] += s_mem_var[t_id + idx]; // 2nd moment reduction
        }
        __syncthreads();
      }
    }

    // reduce smem within warp
    if (t_id < 32) {
      warp_reduce(s_mem_mu, t_id, d);               // 1st moment reduction
      warp_reduce(s_mem_var, t_id, d);              // 2nd moment reduction
    }

    if (t_id == 0) {
      // compute sample mu and var to update streaming stats
      sample_mu = s_mem_mu[0] / D;
      sample_var = (s_mem_var[0] / D) - (sample_mu * sample_mu);

      // update streaming stats
      diff = sample_mu - s_mu[c];
      s_var[c] = afwd * s_var[c] + (1. - afwd) * sample_var + afwd * (1. - afwd) * diff * diff;
      s_mu[c] = s_mu[c] + (1. - afwd) * diff;
    }
    __syncthreads();
  }
}

std::vector<at::Tensor> norm_fwd_cuda(
    const at::Tensor input,
    at::Tensor s_mu,
    at::Tensor s_var,
    const float afwd,
    const float eps) {
  CHECK_INPUT(input);
  CHECK_INPUT(s_mu);
  CHECK_INPUT(s_var);

  // Assumes channel_first contiguous data

  const unsigned int N = input.size(0);
  const unsigned int C = input.size(1);
  const unsigned int D = input[0][0].numel();

  auto scale = at::empty({N, C}, input.type());
  auto out = at::empty_like(input);
  
  const unsigned int threads = min(int(D), 512);
  const dim3 blocks(C);

  AT_DISPATCH_FLOATING_TYPES_AND_HALF(input.scalar_type(), "norm_fwd", ([&] {
    norm_fwd_kernel<scalar_t><<<blocks, threads, 2 * threads * sizeof(float)>>>(
        input.data<scalar_t>(),
        s_mu.data<float>(),
        s_var.data<float>(),
        scale.data<scalar_t>(),
        out.data<scalar_t>(),
        C, N, D, afwd, eps);
  }));
  THCudaCheck(cudaGetLastError());

  return {out, scale, s_mu, s_var};
}

/*
 * OnlineNorm backward kernel implementation
 * The ON bwd algorithm is:
 *
 *    grad_tmp = grad_out - (1 - abwd) v_ctrl * out
 *    v_ctrl = v_ctrl + mean(grad_tmp * out)
 *    grad_tmp = grad_tmp / scale
 *    grad_in = grad_tmp - (1 - abwd) u_ctrl
 *    u_ctrl = u_ctrl + mean(grad_in)
 *
 * where out is the output of ON, scale is the std. dev. used to scale the data
 * in the fwd pass, grad_out is the gradient of the output, grad_in is the
 * gradient of the input, v_ctrl is the v control variable, u_ctrl is the u
 * control variable, abwd is the backward decay factor, and mean(.) is the mean
 * operator.
 *
 * The ON algorithm loops over N samples. Each sample has an associated
 * grad_out, out, and scale. The v and u control variables are applied to the
 * the gradient to produce the gradient of the input. s_mem_v and s_mem_u are
 * shared memory used in the reduction (reduction over D) needed to update
 * v_ctrl and u_ctrl. Each thread block operates on an one of C features
 * (ie. channel when operating on spatial data). Each channel has a v and u
 * control variable which are updated per sample by the reductions per thread
 * block.
 *
 * The kernel assumes contiguous inputs inputs of shape (N, C, *) where D is
 * the product of *.
 */
template <typename scalar_t>
__global__ void norm_bwd_kernel(
    const scalar_t* __restrict__ grad_out,
    float* v_ctrl,
    float* u_ctrl,
    const scalar_t* __restrict__ out,
    const scalar_t* __restrict__ scale,
    scalar_t* __restrict__ grad_in,
    const unsigned int C, const unsigned int N, const unsigned int D,
    const float abwd) {

  const unsigned int t_id = threadIdx.x;
  const unsigned int c = blockIdx.x;
  const unsigned int d = blockDim.x;
  unsigned int idx3, idx;

  extern __shared__ float s_mem_v[];
  float *s_mem_u = &s_mem_v[d];

  scalar_t grad_tmp;

  for(int n = 0; n < N; ++n){
    s_mem_v[t_id] = 0;                              // reset v_ctrl shared mem
    s_mem_u[t_id] = 0;                              // reset u_ctrl shared mem
    for (idx = t_id; idx < D; idx += d) {
      idx3 = Idx3(n, c, idx, N, C, D);              // idx in global mem

      // v_ctrl logic
      grad_tmp = grad_out[idx3] - \
          (scalar_t)((1. - abwd)) * (scalar_t)(v_ctrl[c]) * out[idx3];
      // start reduction for v_ctrl updt
      s_mem_v[t_id] += (float)(grad_tmp) * (float)(out[idx3]);
      
      // scale grad
      grad_tmp = grad_tmp / scale[Idx2(n, c, N, C)];

      // u_ctrl logic
      grad_tmp = grad_tmp - (scalar_t)((1. - abwd)) * (scalar_t)(u_ctrl[c]);
      grad_in[idx3] = grad_tmp;
      // start reduction for u_ctrl updt
      s_mem_u[t_id] += (float)(grad_tmp);
    }
    __syncthreads();

    // reduce within thread block % warp reduction
    for (idx = 512; idx > 32; idx /= 2) {
      if (d > idx) {
        if ((t_id < idx) && ((t_id + idx) < d)) {
          s_mem_v[t_id] += s_mem_v[t_id + idx];
          s_mem_u[t_id] += s_mem_u[t_id + idx];
        }
        __syncthreads();
      }
    }

    // reduce smem within warp
    if (t_id < 32) {
      warp_reduce(s_mem_v, t_id, d);
      warp_reduce(s_mem_u, t_id, d);
    }

    // move reduction to global mem to updt ctrl variables
    if (t_id == 0) {
      v_ctrl[c] += (s_mem_v[0] / D);    // update v_ctrl
      u_ctrl[c] += (s_mem_u[0] / D);    // update u_ctrl
    }
    __syncthreads();
  }
  __syncthreads();
}

std::vector<at::Tensor> norm_bwd_cuda(
    const at::Tensor grad_out,
    at::Tensor u,
    at::Tensor v,
    const at::Tensor out,
    const at::Tensor scale,
    const float abwd) {
  CHECK_INPUT(grad_out);
  CHECK_INPUT(u);
  CHECK_INPUT(v);
  CHECK_INPUT(out);
  CHECK_INPUT(scale);

  // Assumes channel_first contiguous data

  const unsigned int N = grad_out.size(0);
  const unsigned int C = grad_out.size(1);
  const unsigned int D = grad_out[0][0].numel();

  auto grad_in = at::empty_like(grad_out);

  const unsigned int threads = min(int(D), 512);
  const dim3 blocks(C);

  AT_DISPATCH_FLOATING_TYPES_AND_HALF(grad_out.scalar_type(), "norm_bwd", ([&] {
    norm_bwd_kernel<scalar_t><<<blocks, threads, 2 * threads * sizeof(float)>>>(
        grad_out.data<scalar_t>(),
        v.data<float>(),
        u.data<float>(),
        out.data<scalar_t>(),
        scale.data<scalar_t>(),
        grad_in.data<scalar_t>(),
        C, N, D, abwd);
  }));
  THCudaCheck(cudaGetLastError());

  return {grad_in, u, v};
}
