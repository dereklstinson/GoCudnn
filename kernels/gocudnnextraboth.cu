#include <cuda.h>
#include <stdbool.h>
#include <cuda_fp16.h>
#define StartAxis(i,axis) int i = blockIdx.axis * blockDim.axis + threadIdx.axis;
#define GRID_LOOP_X(i, n)                                 \
    for (int i = blockIdx.x * blockDim.x + threadIdx.x; i < n; \
         i += blockDim.x * gridDim.x)

#define GRID_AXIS_LOOP(i, n, axis)                                 \
    for (int i = blockIdx.axis * blockDim.axis + threadIdx.axis; i < n; \
         i += blockDim.axis * gridDim.axis)





__device__ __half2  h2agtb(__half2 a, __half2 b, __half gtval, __half leval ){
    if (__hbgt2(a,b)){
        return __halves2half2(gtval,gtval);
    } 
        return __halves2half2(__hgt(__low2half(a),__low2half(b)) ? gtval : leval,
                              __hgt(__high2half(a),__high2half(b)) ? gtval : leval); 
    
 }
__device__ __half2  h2ageb(__half2 a, __half2 b, __half geval, __half ltval ){
  
    if (__hbge2(a,b)){
    return __halves2half2(geval,geval);
    }
    return __halves2half2(__hge(__low2half(a),__low2half(b)) ? geval : ltval,
                          __hge(__high2half(a),__high2half(b)) ? geval : ltval);
  
}
__device__ __half2  h2altb(__half2 a, __half2 b, __half geval, __half ltval ){
    if (__hblt2(a,b)){
    return __halves2half2(ltval,ltval);
    }
    return __halves2half2(__hlt(__low2half(a),__low2half(b)) ?ltval: geval,
                          __hlt(__high2half(a),__high2half(b)) ?ltval: geval);
  }
__device__ __half2  h2aleb(__half2 a, __half2 b, __half gtval, __half leval ){
    if (__hble2(a,b)){
    return __halves2half2(leval,leval);
    }
    return __halves2half2(__hle(__low2half(a),__low2half(b)) ?leval: gtval,
                          __hle(__high2half(a),__high2half(b)) ?leval: gtval);
}

extern "C" __global__ void Transpose(int numthreads,
               const float *src,
               const int *buf,
               const int ndims,
               float *dest)
{
    const int *src_strides = buf; 
    const int *dest_strides = &buf[ndims];
    const int *perm = &buf[ndims * 2];

    GRID_LOOP_X(destIdx, numthreads)
    {
        int srcIdx = 0;
        int t = destIdx;
        for (int i = 0; i < ndims; ++i)
        {
            const int ratio = t / dest_strides[i];
            t -= ratio * dest_strides[i];
            srcIdx += (ratio * src_strides[perm[i]]);
        }
        dest[destIdx] = src[srcIdx];
    }  
}



/*SwapEveryOther will swap the batches between 2 tensors. 
 It will be either the even or the odd.
   Both tensors have to be equal in size and dims.
   if even is >0 then it will do the even batches.
   Make sure labels are swapped on host end.
   */
extern "C" __global__ void SwapEveryOther(
    const int xThreads, //total batches
    const int totalbatches,
    float *t1,
    float *t2,
   const int start,
const int stride)
{
const int BVol = xThreads;

            for (int i =start;i<totalbatches;i+=stride)
        {   
                GRID_LOOP_X(xIdx, xThreads)
                { 
                    const float swapper =  t1[(i*BVol)+(xIdx)];
                    t1[(i*BVol) +xIdx]=t2[(i*BVol)+xIdx];
                    t2[(i*BVol)+xIdx]=swapper;
                }

            __syncthreads();
        }    
}



//SwapUpperLower will swap either the upper or lower batches
//Right Now inverse doesn't do anything
extern "C" __global__ void SwapUpperLower(
    const int xThreads, //batchsize
    const int yThreads, //batchvol
    float *t1,
    float *t2,
    const int t1upper,
    const int t2upper,
    const int inverse)
{
const int BVol = yThreads;
  
    if (t1upper>0)
    {
        GRID_AXIS_LOOP(xIdx, xThreads/2,x)
        { 
            int t2Idx;
            if (t2upper>0){
                t2Idx=xIdx;
            }else{
                t2Idx=xThreads/2 +xIdx;
            }
           
            if (xIdx < xThreads && t2Idx<xThreads)
            {
                GRID_AXIS_LOOP(yIdx, yThreads,y)
                {
                    
                    const float swapper =  t1[(xIdx*BVol)+(yIdx)];
                    t1[(xIdx*BVol) +yIdx]=t2[(t2Idx*BVol)+yIdx];
                    t2[(xIdx*BVol)+yIdx]=swapper;
                } 
            }
        }   
    }
    else  
    {
        GRID_AXIS_LOOP(xIdx, xThreads/2,x)
        {
            const int halfIdx=(xThreads/2)+xIdx;
            int t2Idx;
            if (t2upper>0){
                t2Idx=xIdx;
            }else{
                t2Idx=halfIdx;
            }
         
            if (halfIdx < xThreads)
            {
                GRID_AXIS_LOOP(yIdx, yThreads,y)
                {
                    const float swapper =  t1[(halfIdx*BVol)+(yIdx)];
                    t1[(halfIdx*BVol) +yIdx]=t2[(t2Idx*BVol)+yIdx];
                    t2[(halfIdx*BVol)+yIdx]=swapper;
                }
            }
        }   
    }
}

   
//ShapetoBatch4DNHWC Does a stride shape to batch. Make sure values on receiving end are set to zero when s2b is 0
extern "C" __global__ void ShapetoBatch4DNHWC(
    const int xThreads,
    const int yThreads,
    const int zThreads,
    const int hSize,
    const int wSize,
    const int num_original_batches,
    const int BatchVolume,
    const int OriginalVol,
    const int N1,
    const int N2,
    const int hstride,
    const int wstride,
    float *shape,
    float *batch,
    const int h_over_scan,
    const int w_over_scan,
    const bool S2B)
{
    int batch0 = N2 * xThreads * yThreads * zThreads;
    int batch1 = xThreads * yThreads * zThreads;
    int batch2 = yThreads * zThreads;
    int batch3 = zThreads;
    for (int b = 0;b<num_original_batches;b++)
    {
        const int ShapeOffset = OriginalVol*b;
        const int BatchOffset=BatchVolume*b;
    for (int i = 0; i < N1; i++)
    {
        for (int j = 0; j < N2; j++)
        {
            GRID_AXIS_LOOP(xIdx, xThreads, x)
            {
                GRID_AXIS_LOOP(yIdx, yThreads, y)
                {
                    GRID_AXIS_LOOP(zIdx, zThreads, z)
                    {

                        int oh = (hstride * i) + xIdx;
                        int ow = (wstride * j) + yIdx;

                        if (S2B)
                        {
                            if (oh < hSize && ow < wSize)
                            {
                                batch[BatchOffset + (i * batch0) + (j * batch1) + (xIdx * batch2) + (yIdx * batch3) + zIdx] =
                                    shape[ShapeOffset + (oh * hSize * zThreads) + (ow * zThreads) + zIdx];
                            }
                            else
                            {
                                if (h_over_scan>0 && ow<wSize){
                                batch[BatchOffset + (i * batch0) + (j * batch1) + (xIdx * batch2) + (yIdx * batch3) + zIdx] = 0;
                                }
                                if (w_over_scan>0 && oh<hSize){
                                    batch[BatchOffset + (i * batch0) + (j * batch1) + (xIdx * batch2) + (yIdx * batch3) + zIdx] = 0;
                                }
                            }
                        }
                        else
                        {
                            shape[ShapeOffset + (oh * hSize * zThreads) + (ow * zThreads) + zIdx] +=
                                batch[BatchOffset + (i * batch0) + (j * batch1) + (xIdx * batch2) + (yIdx * batch3) + zIdx];
                        }
                    }
                }
            }
        }
    }
}
}



//ShapetoBatch4DNCHW Does a stride shape to batch. Make sure values on receiving end are set to zero when s2b is 0


extern "C" __global__ void ShapetoBatch4DNCHW(
    const int xThreads,
    const int yThreads,
    const int zThreads,
    const int hSize,
    const int wSize,
    const int num_original_batches,
    const int BatchVolume,
    const int OriginalVol,
    const int N1,
    const int N2,
    const int hstride,
    const int wstride,
    float *shape,
    float *batch,
    const int h_over_scan,
    const int w_over_scan,
    const bool S2B)
{
    int batch0 = N2 * xThreads * yThreads * zThreads;
    int batch1 = xThreads * yThreads * zThreads;
    int batch2 = xThreads * yThreads;
    int batch3 = yThreads;
    for (int b = 0;b<num_original_batches;b++)
    {
        const int ShapeOffset = OriginalVol*b;
        const int BatchOffset=BatchVolume*b;
    for (int i = 0; i < N1; i++)
    {
        for (int j = 0; j < N2; j++)
        {
            GRID_AXIS_LOOP(xIdx, xThreads, x)
            {
                GRID_AXIS_LOOP(yIdx, yThreads, y)
                {
                    GRID_AXIS_LOOP(zIdx, zThreads, z)
                    {

                        int oh = (hstride * i) + yIdx;
                        int ow = (wstride * j) + zIdx;

                        if (S2B )
                        {
                            if (oh < hSize && ow < wSize)
                            {
                                batch[BatchOffset + (i * batch0) + (j * batch1) + (xIdx * batch2) + (yIdx * batch3) + zIdx] =
                                    shape[ShapeOffset + (xIdx * wSize * hSize) + (oh * wSize) + ow];
                            }
                            else
                            {
                                if (h_over_scan>0 && ow<wSize){
                                    batch[BatchOffset + (i * batch0) + (j * batch1) + (xIdx * batch2) + (yIdx * batch3) + zIdx] = 0;
                                }
                                if (w_over_scan>0 && oh<hSize){
                                    batch[BatchOffset + (i * batch0) + (j * batch1) + (xIdx * batch2) + (yIdx * batch3) + zIdx] = 0; 
                                }
                               
                            }
                        }
                        else
                        {
                            shape[ShapeOffset + (xIdx * wSize * hSize) + (oh * wSize) + ow] +=
                                batch[BatchOffset + (i * batch0) + (j * batch1) + (xIdx * batch2) + (yIdx * batch3) + zIdx];
                        }
                    }
                }
            }
        }
    }
}
}


extern "C" __global__ void NearestNeighborNHWC(
    const int aligncorners,
    const int threads,
    const float *src,
    const int src_height,
    const int src_width,
    const int channels,
    const int dest_height,
    const int dest_width,
    const float height_scale,
    const float width_scale,
    float *dest)
{
    GRID_LOOP_X(i, threads)
    {
        int n = i;
        int c = n % channels;
        n /= channels;
        int dest_x = n % dest_width;
        n /= dest_width;
        int dest_y = n % dest_height;
        n /= dest_height;
        const float *src_data_n = &src[n * channels * src_height * src_width];
        const int src_y = fminf((aligncorners) ? (roundf(dest_y * height_scale))
                                               : (floorf(dest_y * height_scale)),
                                src_height - 1);

        const int src_x = fminf((aligncorners) ? (roundf(dest_x * width_scale))
                                               : (floorf(dest_x * width_scale)),
                                src_width - 1);
        const int idx = (src_y * src_width + src_x) * channels + c;
        dest[i] = src_data_n[idx];
    }
}
extern "C" __global__ void NearestNeighborNCHW(
    const int aligncorners,
    const int threads,
    const float *src,
    const int src_height,
    const int src_width,
    const int channels,
    const int dest_height,
    const int dest_width,
    const float height_scale,
    const float width_scale,
    float *dest)
{
    GRID_LOOP_X(i, threads)
    {
        int n = i;
        int dest_x = n % dest_width;
        n /= dest_width;
        int dest_y = n % dest_height;
        n /= dest_height;
        int c = n % channels;
        n /= channels;
        const float *src_data_n = &src[n * channels * src_height * src_width];
        const int src_y = fminf((aligncorners) ? (roundf(dest_y * height_scale))
                                               : (floorf(dest_y * height_scale)),
                                src_height - 1);

        const int src_x = fminf((aligncorners) ? (roundf(dest_x * width_scale))
                                               : (floorf(dest_x * width_scale)),
                                src_width - 1);
        const int idx = (c * src_height * src_width) + (src_y * src_width) + src_x;
        dest[i] = src_data_n[idx];
    }
}
extern "C" __global__ void NearestNeighborNCHWBack(
    const int aligncorners,
    const int threads,
    float *src,
    const int src_height,
    const int src_width,
    const int channels,
    const int dest_height,
    const int dest_width,
    const float height_scale,
    const float width_scale,
    float *dest)
{
    GRID_LOOP_X(i, threads)
    {
        int n = i;
        int src_x = n % src_width;
        n /= src_width;
        int src_y = n % src_height;
        n /= src_height;
        int c = n % channels;
        n /= channels;
        float *src_data_n = &src[n * channels * src_height * src_width];
        const int dest_y = fminf((aligncorners) ? (roundf(src_y * height_scale))
                                                : (floorf(src_y * height_scale)),
                                 dest_height - 1);

        const int dest_x = fminf((aligncorners) ? (roundf(src_x * width_scale))
                                                : (floorf(src_x * width_scale)),
                                 dest_width - 1);
        const int idx = (c * dest_width * dest_height) + (dest_y * dest_width) + dest_x;
        atomicAdd(&src_data_n[idx], dest[i]);
    }
}
extern "C" __global__ void NearestNeighborNHWCBack(
    const int aligncorners,
    const int threads,
    float *src,
    const int src_height,
    const int src_width,
    const int channels,
    const int dest_height,
    const int dest_width,
    const float height_scale,
    const float width_scale,
    float *dest)
{
    GRID_LOOP_X(i, threads)
    {
        int n = i;
        int c = n % channels;
        n /= channels;
        int src_x = n % src_width;
        n /= src_width;
        int src_y = n % src_height;
        n /= src_height;
        float *src_data_n = &src[n * channels * src_height * src_width];
        const int dest_y = fminf((aligncorners) ? (roundf(src_y * height_scale))
                                                : (floorf(src_y * height_scale)),
                                 dest_height - 1);

        const int dest_x = fminf((aligncorners) ? (roundf(src_x * width_scale))
                                                : (floorf(src_x * width_scale)),
                                 dest_width - 1);
        const int idx = (dest_y * dest_width + dest_x) * channels + c;
        atomicAdd(&src_data_n[idx], dest[i]);
    }
}
extern "C" __global__ void AdaGrad(const int length,
                                        float *weights,   //weights input and output
                                        float *dw,        //input and will have to set to zero
                                        float *gsum,      //storage
                                        const float rate, //input
                                        const float eps,
                                        const float dwalpha)
{ //input
    GRID_LOOP_X(cell, length)
    {
        gsum[cell] =  gsum[cell] + (dw[cell] * dw[cell]);
        weights[cell] += -(rate * dw[cell]) / (sqrtf(gsum[cell]) + eps);
        dw[cell] = dw[cell]*dwalpha; //smoothing factor.
    }
}


extern "C" __global__ void Adam(const int n,
                                     float *w,
                                     float *gsum,
                                     float *xsum,
                                     float *dw,
                                     const float rate,
                                     const float beta1,
                                     const float beta2,
                                     const float eps,
                                     const float denombeta1,
                                     const float denombeta2,
                                     const float dwalpha)
{

    GRID_LOOP_X(i, n)
    {
      
        gsum[i] = (beta1 * gsum[i]) + ((1.0 - beta1) * dw[i]);
        float gsumt = gsum[i] /denombeta1;
        xsum[i] = (beta2 * xsum[i]) + ((1.0 - beta2) * (dw[i] * dw[i]));
        float xsumt = xsum[i] / denombeta2;
        w[i] += -(rate * gsumt) / (sqrtf(xsumt) + eps);
        dw[i]=  dwalpha*dw[i]; //smoothing factor
    }
  
}

extern "C" __global__ void AdaDelta(const int length,
                                         float *weights,   //weights input and output
                                         float *gsum,      //storage
                                         float *xsum,      //storage
                                         float *dw,        //input and will have to set to zero
                                         const float rate, //input
                                         const float eps,
                                         const float ro,
                                         const float dwalpha)
{

    GRID_LOOP_X(i, length)
    {

        gsum[i] = (ro * gsum[i]) + ((1.0-ro)*dw[i] * dw[i]);
        const float dx = sqrtf((xsum[i]+eps)/(gsum[i]+eps))*dw[i];
        xsum[i]=(ro*xsum[i])+((1-ro)*dx*dx);
        weights[i] -= dx;
        dw[i] = dw[i]*dwalpha;
    }
}
/*
//This is paired with the host
extern "C" __global__ void Segment1stDim(const int start_index, const float *src, float *dst, const int size)
{
    int i = (blockIdx.y * gridDim.x * blockDim.x) + (blockIdx.x * blockDim.x) + threadIdx.x;
    int start_location = start_index * size;
    if (i < size)
    {
        dst[i] = src[start_location + i];
    }
}
//This is paired with the host
extern "C" __global__ void Segment1stDimhalf(const int start_index, const __half *src, __half *dst, const int size)
{
    int i = (blockIdx.y * gridDim.x * blockDim.x) + (blockIdx.x * blockDim.x) + threadIdx.x;
    int start_location = start_index * size;
    if (i < size)
    {
        dst[i] = src[start_location + i];
    }
}
*/
extern "C" __global__ void L1L2(
    const int length,
    float *dw,          //input and output
    const float *w,     //input needs to ba an array
    float *l1,          //output set to zero
    float *l2,          //output set to zero
    const float batch,  // should be an int but just send it as a float
    const float decay1, //input
    const float decay2)
{ //input

    GRID_LOOP_X(i, length)
    {

        atomicAdd(l1, abs(w[i]) * decay1);
        atomicAdd(l2, (w[i] * w[i] * decay2) / 2.0);
        const float gradl1 = decay1 * (w[i] > 0 ? 1 : -1);
        const float gradl2 = w[i] * decay2;
        dw[i] = (dw[i] + gradl2 + gradl1) / batch;
    }
}
//ThreshForward is kind of memory expensive, mostly because it is experimental.
//To test start the positive at random uniform numbers between .9 and 1.1
//and do the negcoefs between .01 and .2 or something along those lines.
//maybe the threshold should be between -.3 and .3 uniform number
extern "C" __global__ void ThreshForward(const int XThreads,
                                         const int batchsize,
                                         const float *x,
                                         float *y,
                                         const float *negcoefs,
                                         const float *threshhold,
                                         const float *poscoefs)
{
    for (int i=0;i<batchsize;i++)
    {
        int stride=XThreads*i;
            GRID_LOOP_X(xIdx,XThreads)
            {
                if (x[stride+xIdx]>threshhold[xIdx])
                {
                    y[stride+xIdx]=  x[stride+xIdx]*poscoefs[xIdx];
                }
                else
                {
                    y[stride+xIdx]=  negcoefs[xIdx]*x[stride+xIdx];
                }
            }
    }
}

//Backward 
// Max(x,thresh)
extern "C" __global__ void ThreshBackward(const int XThreads,
                                          const int batchsize,
                                          const float *x,
                                          float *dx,
                                          const float *dy,
                                          const float *negcoefs,
                                          float *dnegcoefs,
                                          const float *threshhold,
                                          float *dthreshhold,
                                          const float *poscoefs,
                                          float *dposcoefs)
{

    for (int i=0;i<batchsize;i++)
    {
        int stride=XThreads*i;
            GRID_LOOP_X(xIdx,XThreads)
            {
                if (x[stride+xIdx]>threshhold[xIdx])  
                {
                    dx[stride+xIdx]=  poscoefs[xIdx]*dy[stride+xIdx];
                    dposcoefs[xIdx]+=dy[xIdx]*x[stride+xIdx];

                }
                else
                {
                    dx[stride+xIdx]=  negcoefs[xIdx]*dy[stride+xIdx];
                    dnegcoefs[xIdx]+=dy[xIdx]*x[stride+xIdx];
                }
                dthreshhold[xIdx]+=dy[xIdx];
            }
    }
}

//forwardPrelu does the forward Prelu
extern "C" __global__ void PreluForward(const int XThreads,
                                        const int batchsize,
                                        const float *x,
                                        float *y,
                                        const float *coefs)
{
  
    for (int i=0;i<batchsize;i++)
    {
        int stride=XThreads*i;
            GRID_LOOP_X(xIdx,XThreads)
            {
                if (x[stride+xIdx]>0)
                {
                    y[stride+xIdx]=  x[stride+xIdx];
                }
                else
                {
                    y[stride+xIdx]=  coefs[xIdx]*x[stride+xIdx];
                }
            }
    }
   
}
//backwardPrelu does the backprop of the parametric float

extern "C" __global__ void PreluBackward(const int XThreads,
                                                          const int batchsize,
                                                          float *dx,
                                                          const float *x,
                                                          const float *dy,
                                                          const float *coefs,
                                                          float *dcoefs)
{
    for (int i=0;i<batchsize;i++)
    {
        int stride=XThreads*i;
            GRID_LOOP_X(xIdx,XThreads)
            {
                if (x[stride+xIdx]>0)
                {
                    dx[stride+xIdx]=  dy[stride+xIdx];
                }
                else
                {
                    dx[stride+xIdx]=  coefs[xIdx]*dy[stride+xIdx];
                    dcoefs[xIdx]+=dy[xIdx]*x[stride+xIdx];
                }
            }
    }
}


/*
Leaky functions
*/

extern "C" __global__ void LeakyForwardAlphaBeta(const int length,
                                             const float *x,
                                             float *y,
                                             const float coef,
                                             const float alpha,
                                              const float beta)
{

    GRID_LOOP_X(i, length)
    {
        const float previous = y[i];
        if (x[i] > 0.0)
        {
            const float current = x[i];
            y[i] = (beta*previous) + (alpha *current) ;
        }
        else
        {
              const float current = x[i]*coef;
           y[i] = (beta*previous) + (alpha *current) ;
        }
          __syncthreads();
    }
}



extern "C" __global__ void LeakyBackwardAlphaBeta(const int length,
                                              const float *x,
                                              float *dx,
                                              const float *dy,
                                              const float coef,
                                              const float alpha,
                                              const float beta)
{

    GRID_LOOP_X(i, length)
    {
        const float previous = dx[i];
        if (x[i] > 0.0)
        {
            const float current= dy[i];
            dx[i] =(beta *previous) + (current * alpha);
        }
        else
        {
            const float current= dy[i]*coef;
            dx[i] = (beta *previous) + (current * alpha);
        }
        __syncthreads();
    }
}
extern "C" __global__ void LeakyForwardAlpha(const int length,
                                             const float *x,
                                             float *y,
                                             const float coef,
                                             const float alpha)
{

    GRID_LOOP_X(i, length)
    {
        
        if (x[i] > 0.0)
        {
            y[i] = alpha *x[i];
        }
        else
        {
            const float current=x[i]*coef;
            y[i] =current * alpha;
        }
         __syncthreads();
    }
}

extern "C" __global__ void LeakyBackwardAlpha(const int length,
                                              const float *x,
                                              float *dx,
                                              const float *dy,
                                              const float coef,
                                              const float alpha)
{
 
    GRID_LOOP_X(i, length)
    {

        if (x[i] > 0.0)
        {
            dx[i] = dy[i]*alpha;
        }
        else   
        {
            const float current=dy[i]*coef;
            dx[i] = current *alpha;
        }
         __syncthreads();
    }
}


extern "C" __global__ void LeakyForward(const int length,
                                             const float *x,
                                             float *y,
                                             const float coef)
{
    GRID_LOOP_X(i, length)
    {
        if (x[i] > 0.0)
        {
            y[i] = x[i];
        }
        else
        {
            y[i] = x[i] * coef;
        }
    }
}

extern "C" __global__ void LeakyBackward(const int length,
                                              const float *x,
                                              float *dx,
                                              const float *dy,
                                              const float coef)
{

    GRID_LOOP_X(i, length)
    {

        if (x[i] > 0.0)
        {

            dx[i] = dy[i];
        }
        else
        {

            dx[i] = dy[i] * coef;
        }
    }
}

extern "C" __global__ void MSELoss(const int length, 
                            float *errors, 
                            const float *target,
                            const float *networkout, 
                            float *loss,
                            const float alpha,
                            const float beta)
{
    
    loss[0]=0;
    GRID_LOOP_X(i, length)
    {
        const float y = networkout[i] - target[i];
        errors[i] = y;
        atomicAdd(loss, (y * y) / 2);
    }

   
}

extern "C" __global__ void MSELossbyBatches(const int xthreads,const int ythreads, float *errors, const float *target, const float *networkout, float *loss)
{

    GRID_AXIS_LOOP(xIdx,xthreads,x)
    {
        const int offset=ythreads*xIdx;
            GRID_AXIS_LOOP(yIdx, ythreads,y)
            {  
             const float y = networkout[offset+yIdx] - target[offset+yIdx];
             errors[offset+yIdx] = y;
             atomicAdd(&loss[xIdx], (y * y) / 2);
            }
    }
}




extern "C" __global__ void ConcatNHWCEX(const int XThreads,
                                        const int YThreads,
                                        const int ZThreads,
                                        const int Batches,
                                        const int DestBatchVol,
                                        const int TotalDestChannels,
                                        const int DestChannelOffset,
                                        float *src,
                                        const float alpha,
                                        const int SrcBatchVol, 
                                        float *dest,
                                        const float beta,
                                        bool forward)
{
for (int i=0;i<Batches;i++){

GRID_AXIS_LOOP(idX,XThreads,x)
{
    GRID_AXIS_LOOP(idY,YThreads,y)
    {
        GRID_AXIS_LOOP(idZ,ZThreads,z)
        {
        int deststride = (i*DestBatchVol)+(idX*YThreads*TotalDestChannels)+(idY*TotalDestChannels)+DestChannelOffset+idZ;
        int srcstride = (i*SrcBatchVol)+(idX*YThreads*ZThreads)+(idY*ZThreads)+idZ;
        if (forward){
            dest[deststride]=src[srcstride]*alpha + dest[deststride]*beta;  
        }else{
            src[srcstride]=dest[deststride]*alpha + src[srcstride]*beta;
        }
         
        }
    }
}

}

}

extern "C" __global__ void ConcatNCHWEX(const int XThreads,
                                        const int Batches,
                                        const int DestBatchVol,
                                        const int DestChannelOffset,
                                        float *src,
                                        const float alpha,
                                        const int SrcBatchVol, 
                                        float *dest,
                                        const float beta,
                                        bool forward)
{
for (int i=0;i<Batches;i++){

GRID_AXIS_LOOP(idX,XThreads,x)
{

        int deststride = (i*DestBatchVol)+(DestChannelOffset+idX);
        int srcstride = (i*SrcBatchVol)+(idX);
         if (forward){
            dest[deststride]=src[srcstride]*alpha + dest[deststride]*beta;  
        }else{
            src[srcstride]=dest[deststride]*alpha + src[srcstride]*beta;
        }
         
        }
    }
}

extern "C" __global__ void ConcatNHWCEXHalf(const int XThreads,
                                        const int YThreads,
                                        const int ZThreads,
                                        const int Batches,
                                        const int DestBatchVol,
                                        const int TotalDestChannels,
                                        const int DestChannelOffset,
                                        __half *src, 
                                        const __half alpha,
                                        const int SrcBatchVol, 
                                        __half *dest,
                                        const __half beta,
                                        bool forward)
{
for (int i=0;i<Batches;i++){

GRID_AXIS_LOOP(idX,XThreads,x)
{
    GRID_AXIS_LOOP(idY,YThreads,y)
    {
        GRID_AXIS_LOOP(idZ,ZThreads,z)
        {
        int deststride = (i*DestBatchVol)+(idX*YThreads*TotalDestChannels)+(idY*TotalDestChannels)+DestChannelOffset+idZ;
        int srcstride = (i*SrcBatchVol)+(idX*YThreads*ZThreads)+(idY*ZThreads)+idZ;
         if (forward){
            dest[deststride]=__hadd(__hmul(src[srcstride],alpha), __hmul(dest[deststride],beta));  
        }else{
            src[srcstride]=__hadd(__hmul(dest[deststride],alpha), __hmul( src[srcstride],beta));
        }
         
        }
    }
}

}

}
extern "C" __global__ void ConcatNCHWEXHalf(const int XThreads,
                                            const int Batches,
                                            const int DestBatchVol,
                                            const int DestChannelOffset,
                                            __half *src, 
                                            const __half alpha,
                                            const int SrcBatchVol, 
                                            __half *dest,
                                            __const __half beta,
                                            bool forward)
{
for (int i=0;i<Batches;i++){

GRID_AXIS_LOOP(idX,XThreads,x)
{

        int deststride = (i*DestBatchVol)+(DestChannelOffset+idX);
        int srcstride = (i*SrcBatchVol)+(idX);
        if (forward){
            dest[deststride]=__hadd(__hmul(src[srcstride],alpha), __hmul(dest[deststride],beta));  
        }else{
            src[srcstride]=__hadd(__hmul(dest[deststride],alpha), __hmul( src[srcstride],beta));
        }
         
        }
    }
}

extern "C" __global__ void ConcatForwardNCHW( const int XThreads,
                                              const int Batches,
                                              const int Channels1,
                                              const int src1vol,
                                              const float *Src1,
                                              const int Channels2,
                                              const int src2vol,
                                              const float *Src2,
                                              float *dest)
{
    for (int i = 0;i<Batches;i++)
    {
        const int Stride= Batches*(src1vol+src2vol);
        const int src1batchstride=src1vol*i;
        const int src2batchstride=src2vol*i;
        for (int j=0;j<Channels1;j++)
        {
            GRID_LOOP_X(xIdx, XThreads)
            {
           dest[Stride+(j*XThreads)+xIdx]  = Src1[src1batchstride+(j*XThreads)+xIdx];
            }
        }
        for (int j=0;j<Channels2;j++){
            GRID_LOOP_X(xIdx, XThreads)
            {
           dest[Stride+(j*XThreads)+src1vol+xIdx]  = Src2[src2batchstride+(j*XThreads)+xIdx];
            }
        }
    }
}
extern "C" __global__ void ConcatBackwardNCHW( const int XThreads,
                                              const int Batches,
                                              const int Channels1,
                                              const int src1vol,
                                               float *Src1,
                                              const int Channels2,
                                              const int src2vol,
                                               float *Src2,
                                              const float *dest)
{
    for (int i = 0;i<Batches;i++)
    {
        const int Stride= Batches*(src1vol+src2vol);
        const int src1batchstride=src1vol*i;
        const int src2batchstride=src2vol*i;
        for (int j=0;j<Channels1;j++)
        {
            GRID_LOOP_X(xIdx, XThreads)
            {
                 Src1[src1batchstride+(j*XThreads)+xIdx]=  dest[Stride+(j*XThreads)+xIdx];  
            }
        }
        for (int j=0;j<Channels2;j++){
            GRID_LOOP_X(xIdx, XThreads)
            {
                Src2[src2batchstride+(j*XThreads)+xIdx]  = dest[Stride+(j*XThreads)+src1vol+xIdx];  
            }
        }
    }
}


extern "C" __global__ void ConcatForwardNCHWhalf( const int XThreads,
                                              const int Batches,
                                              const int Channels1,
                                              const int src1vol,
                                              const __half *Src1,
                                              const int Channels2,
                                              const int src2vol,
                                              const __half *Src2,
                                              __half *dest)
{
    for (int i = 0;i<Batches;i++)
    {
        const int Stride= Batches*(src1vol+src2vol);
        const int src1batchstride=src1vol*i;
        const int src2batchstride=src2vol*i;
        for (int j=0;j<Channels1;j++)
        {
            GRID_LOOP_X(xIdx, XThreads)
            {
           dest[Stride+(j*XThreads)+xIdx]  = Src1[src1batchstride+(j*XThreads)+xIdx];
            }
        }
        for (int j=0;j<Channels2;j++){
            GRID_LOOP_X(xIdx, XThreads)
            {
           dest[Stride+(j*XThreads)+src1vol+xIdx]  = Src2[src2batchstride+(j*XThreads)+xIdx];
            }
        }
    }
}
extern "C" __global__ void ConcatBackwardNCHWhalf( const int XThreads,
                                                   const int Batches,
                                                   const int Channels1,
                                                   const int src1vol,
                                               __half *Src1,
                                              const int Channels2,
                                              const int src2vol,
                                               __half *Src2,
                                              const __half *dest)
{
    for (int i = 0;i<Batches;i++)
    {
        const int Stride= Batches*(src1vol+src2vol);
        const int src1batchstride=src1vol*i;
        const int src2batchstride=src2vol*i;
        for (int j=0;j<Channels1;j++)
        {
            GRID_LOOP_X(xIdx, XThreads)
            {
                 Src1[src1batchstride+(j*XThreads)+xIdx]=  dest[Stride+(j*XThreads)+xIdx];  
            }
        }
        for (int j=0;j<Channels2;j++){
            GRID_LOOP_X(xIdx, XThreads)
            {
                Src2[src2batchstride+(j*XThreads)+xIdx]  = dest[Stride+(j*XThreads)+src1vol+xIdx];  
            }
        }
    }
}
//MakePlanarImageBatchesUint8 - for this to work all the each batch should have the same amount of channels and all the channels
//need to be the same size 
extern "C" __global__ void MakePlanarImageBatchesUint8(const int XThreads, //Should be channel size
                                                 const int Batches,
                                                 const int channelsperbatch,
                                                 const float *Srcs, //all the channels for everything.
                                                 float *dest)
{
    const int batchsize = XThreads*channelsperbatch;
    for (int i = 0;i<Batches;i++)
    {
        for (int j = 0;j<channelsperbatch;j++)
        {
            GRID_LOOP_X(xIdx, XThreads)
            {
               dest[(i*batchsize)+(j*XThreads)+xIdx]=Srcs[(j*XThreads)+xIdx];
            }
        }
    
    }
}

extern "C" __global__ void TransposeFP16(int numthreads,
               const __half *src,
               const int *buf,
               const int ndims,
               __half *dest)
{
    const int *src_strides = buf; 
    const int *dest_strides = &buf[ndims];
    const int *perm = &buf[ndims * 2];

    GRID_LOOP_X(destIdx, numthreads)
    {
        int srcIdx = 0;
        int t = destIdx;
        for (int i = 0; i < ndims; ++i)
        {
            const int ratio = t / dest_strides[i];
            t -= ratio * dest_strides[i];
            srcIdx += (ratio * src_strides[perm[i]]);
        }
        dest[destIdx] = src[srcIdx];
    }  
}




extern "C" __global__ void SwapEveryOtherFP16(
    const int n, //total batches
    const int totalbatches,
    __half *t1,
    __half *t2,
   const int start,
const int stride)
{
StartAxis(stx,x)
const int BVol = n/2;
__half2 *t1h=(half2 *)t1;
__half2 *t2h=(half2 *)t2;

            for (int i =start;i<totalbatches;i+=stride)
        {
     
            
                GRID_LOOP_X(xIdx, BVol)
                { 
                    const __half2 swapper =  t1h[(i*BVol)+(xIdx)];
                    t1h[(i*BVol) +xIdx]=t2h[(i*BVol)+xIdx];
                    t2h[(i*BVol)+xIdx]=swapper;
                }
                if (stx==0 && (n%2)){
                    const int xIdx=n-1;
                    const __half swapper =  t1[(i*n)+(xIdx)];
                    t1[(i*n) +(xIdx)]=t1[(i*n)+(xIdx)];
                    t2[(i*n)+(xIdx)]=swapper;
                }

            __syncthreads();
        }      
}
extern "C" __global__ void SwapUpperLowerFP16(
    const int xThreads, //batchsize
    const int yThreads, //batchvol
    __half *t1,
    __half *t2,
    const int t1upper,
    const int t2upper,
    const int inverse)
{
const int BVol = yThreads;
    if (t1upper>0)
    {
        GRID_AXIS_LOOP(xIdx,xThreads/2,x)
        { 
            int t2Idx;
            if (t2upper>0){
                t2Idx=xIdx;
            }else{
                t2Idx=xThreads/2 +xIdx;
            }
           
            if (xIdx < xThreads && t2Idx<xThreads)
            {
                GRID_AXIS_LOOP(yIdx, BVol,y)
                {
                    
                    const __half swapper =  t1[(xIdx*BVol)+(yIdx)];
                    t1[(xIdx*BVol) +yIdx]=t2[(t2Idx*BVol)+yIdx];
                    t2[(xIdx*BVol)+yIdx]=swapper;
                } 
            }
        }
       
    }
    else  
    {
        GRID_AXIS_LOOP(xIdx, xThreads/2,x)
        {
            const int halfIdx=(xThreads/2)+xIdx;
            int t2Idx;
            if (t2upper>0){
                t2Idx=xIdx;
            }else{
                t2Idx=halfIdx;
            }
         
            if (halfIdx < xThreads)
            {
                GRID_AXIS_LOOP(yIdx, yThreads,y)
                {
                    const __half swapper =  t1[(halfIdx*BVol)+(yIdx)];
                    t1[(halfIdx*BVol) +yIdx]=t2[(t2Idx*BVol)+yIdx];
                    t2[(halfIdx*BVol)+yIdx]=swapper;
                }
            }
        }   
    }
}


//ShapetoBatch4DNHWC Does a stride shape to batch. Make sure values on receiving end are set to zero when s2b is 0
extern "C" __global__ void ShapetoBatch4DNHWCFP16(
    const int xThreads,
    const int yThreads,
    const int zThreads,
    const int hSize,
    const int wSize,
    const int num_original_batches,
    const int BatchVolume,
    const int OriginalVol,
    const int N1,
    const int N2,
    const int hstride,
    const int wstride,
    __half *shape,
    __half *batch,
    const int h_over_scan,
    const int w_over_scan,
    const bool S2B)
{
    int batch0 = N2 * xThreads * yThreads * zThreads;
    int batch1 = xThreads * yThreads * zThreads;
    int batch2 = yThreads * zThreads;
    int batch3 = zThreads;
    for (int b = 0;b<num_original_batches;b++)
    {
        const int ShapeOffset = OriginalVol*b;
        const int BatchOffset=BatchVolume*b;
    for (int i = 0; i < N1; i++)
    {
        for (int j = 0; j < N2; j++)
        {
            GRID_AXIS_LOOP(xIdx, xThreads, x)
            {
                GRID_AXIS_LOOP(yIdx, yThreads, y)
                {
                    GRID_AXIS_LOOP(zIdx, zThreads, z)
                    {

                        int oh = (hstride * i) + xIdx;
                        int ow = (wstride * j) + yIdx;

                        if (S2B)
                        {
                            if (oh < hSize && ow < wSize)
                            {
                                batch[BatchOffset + (i * batch0) + (j * batch1) + (xIdx * batch2) + (yIdx * batch3) + zIdx] =
                                    shape[ShapeOffset + (oh * hSize * zThreads) + (ow * zThreads) + zIdx];
                            }
                            else
                            {
                                if (h_over_scan>0 && ow<wSize){
                                batch[BatchOffset + (i * batch0) + (j * batch1) + (xIdx * batch2) + (yIdx * batch3) + zIdx] = 0;
                                }
                                if (w_over_scan>0 && oh<hSize){
                                    batch[BatchOffset + (i * batch0) + (j * batch1) + (xIdx * batch2) + (yIdx * batch3) + zIdx] = 0;
                                }
                            }
                        }
                        else
                        {
                            shape[ShapeOffset + (oh * hSize * zThreads) + (ow * zThreads) + zIdx] +=
                                batch[BatchOffset + (i * batch0) + (j * batch1) + (xIdx * batch2) + (yIdx * batch3) + zIdx];
                        }
                    }
                }
            }
        }
    }
}
}



extern "C" __global__ void ShapetoBatch4DNCHWFP16(
    const int xThreads,
    const int yThreads,
    const int zThreads,
    const int hSize,
    const int wSize,
    const int num_original_batches,
    const int BatchVolume,
    const int OriginalVol,
    const int N1,
    const int N2,
    const int hstride,
    const int wstride,
    __half *shape,
    __half *batch,
    const int h_over_scan,
    const int w_over_scan,
    const bool S2B)
{
    int batch0 = N2 * xThreads * yThreads * zThreads;
    int batch1 = xThreads * yThreads * zThreads;
    int batch2 = xThreads * yThreads;
    int batch3 = yThreads;
    for (int b = 0;b<num_original_batches;b++)
    {
        const int ShapeOffset = OriginalVol*b;
        const int BatchOffset=BatchVolume*b;
    for (int i = 0; i < N1; i++)
    {
        for (int j = 0; j < N2; j++)
        {
            GRID_AXIS_LOOP(xIdx, xThreads, x)
            {
                GRID_AXIS_LOOP(yIdx, yThreads, y)
                {
                    GRID_AXIS_LOOP(zIdx, zThreads, z)
                    {

                        int oh = (hstride * i) + yIdx;
                        int ow = (wstride * j) + zIdx;

                        if (S2B )
                        {
                            if (oh < hSize && ow < wSize)
                            {
                                batch[BatchOffset + (i * batch0) + (j * batch1) + (xIdx * batch2) + (yIdx * batch3) + zIdx] =
                                    shape[ShapeOffset + (xIdx * wSize * hSize) + (oh * wSize) + ow];
                            }
                            else
                            {
                                if (h_over_scan>0 && ow<wSize){
                                    batch[BatchOffset + (i * batch0) + (j * batch1) + (xIdx * batch2) + (yIdx * batch3) + zIdx] = 0;
                                }
                                if (w_over_scan>0 && oh<hSize){
                                    batch[BatchOffset + (i * batch0) + (j * batch1) + (xIdx * batch2) + (yIdx * batch3) + zIdx] = 0; 
                                }
                               
                            }
                        }
                        else
                        {
                            shape[ShapeOffset + (xIdx * wSize * hSize) + (oh * wSize) + ow] +=
                                batch[BatchOffset + (i * batch0) + (j * batch1) + (xIdx * batch2) + (yIdx * batch3) + zIdx];
                        }
                    }
                }
            }
        }
    }
}
}

extern "C" __global__ void NearestNeighborNCHWFP16(
    const int aligncorners,
    const int threads,
    const __half *src,
    const int src_height,
    const int src_width,
    const int channels,
    const int dest_height,
    const int dest_width,
    const float height_scale,
    const float width_scale,
    __half *dest)
{
    GRID_LOOP_X(i, threads)
    {
        int n = i;
        int dest_x = n % dest_width;
        n /= dest_width;
        int dest_y = n % dest_height;
        n /= dest_height;
        int c = n % channels;
        n /= channels;
        const __half *src_data_n = &src[n * channels * src_height * src_width];
        const int src_y = fminf((aligncorners) ? (roundf(dest_y * height_scale))
                                               : (floorf(dest_y * height_scale)),
                                src_height - 1);

        const int src_x = fminf((aligncorners) ? (roundf(dest_x * width_scale))
                                               : (floorf(dest_x * width_scale)),
                                src_width - 1);
        const int idx = (c * src_height * src_width) + (src_y * src_width) + src_x;
        dest[i] = src_data_n[idx];
    }
}

#if __CUDA_ARCH__ >= 750 //might not work on other architectures. will probably work best with even tensors.
extern "C" __global__ void NearestNeighborNHWCBackFP16(
    const int aligncorners,
    const int threads,
    __half *src,
    const int src_height,
    const int src_width,
    const int channels,
    const int dest_height,
    const int dest_width,
    const float height_scale,
    const float width_scale,
    __half *dest)
{
    GRID_LOOP_X(i, threads)
    {
        int n = i;
        int c = n % channels;
        n /= channels;
        int src_x = n % src_width;
        n /= src_width;
        int src_y = n % src_height;
        n /= src_height;
        __half *src_data_n = &src[n * channels * src_height * src_width];
        const int dest_y = fminf((aligncorners) ? (roundf(src_y * height_scale))
                                                : (floorf(src_y * height_scale)),
                                 dest_height - 1);

        const int dest_x = fminf((aligncorners) ? (roundf(src_x * width_scale))
                                                : (floorf(src_x * width_scale)),
                                 dest_width - 1);
        const int idx = (dest_y * dest_width + dest_x) * channels + c;

        atomicAdd(&src_data_n[idx], dest[i]);
    }
}
#else
extern "C" __global__ void NearestNeighborNHWCBackFP16(
    const int aligncorners,
    const int threads,
    __half *src,
    const int src_height,
    const int src_width,
    const int channels,
    const int dest_height,
    const int dest_width,
    const float height_scale,
    const float width_scale,
    __half *dest)
{
    
      const __half zer0= __float2half(0.0);
    GRID_LOOP_X(i, threads-1) //minus one because I do a conversion to half2 wich is 32bit to do the atomic add and don't want to run into space outside of array 
      
    {
        int n = i;
        int c = n % channels;
        n /= channels;
        int src_x = n % src_width;
        n /= src_width;
        int src_y = n % src_height;
        n /= src_height;
        __half *src_data_n = &src[n * channels * src_height * src_width];
        const int dest_y = fminf((aligncorners) ? (roundf(src_y * height_scale))
                                                : (floorf(src_y * height_scale)),
                                 dest_height - 1);

        const int dest_x = fminf((aligncorners) ? (roundf(src_x * width_scale))
                                                : (floorf(src_x * width_scale)),
                                 dest_width - 1);
        const int idx = (dest_y * dest_width + dest_x) * channels + c;
        const __half2 dsth2 = __halves2half2(dest[i],zer0);   // This should give us the value half2[dest,0]
        void *vdptr=(void*)(&src_data_n[idx]);  //I don't know if I need to do this, but I work with go a lot and wanted to make sure it was going to step correctly
        __half2 *srch2hack = (__half2*)(vdptr); //Here say the void pointer address into srch2hack
        atomicAdd(srch2hack,dsth2); // this should be (src_data_n[idx]+dest[i], src_data_n[idx+1]+0)  //had to do threads -1 so in the last part we don't overstep the bounds
    }
    //This last part is to do the last value in dest.
     int n = threads-1;
       int c = n % channels;
        n /= channels;
        int src_x = n % src_width;
        n /= src_width;
        int src_y = n % src_height;
        n /= src_height;
        __half *src_data_n = &src[n * channels * src_height * src_width];
        const int dest_y = fminf((aligncorners) ? (roundf(src_y * height_scale))
                                                : (floorf(src_y * height_scale)),
                                 dest_height - 1);

        const int dest_x = fminf((aligncorners) ? (roundf(src_x * width_scale))
                                                : (floorf(src_x * width_scale)),
                                 dest_width - 1);
        const int idx = (dest_y * dest_width + dest_x) * channels + c;
         src_data_n[idx] = __hadd(src_data_n[idx], dest[threads-1]);
}

#endif

extern "C" __global__ void NearestNeighborNHWCFP16(
    const int aligncorners,
    const int threads,
    const __half *src,
    const int src_height,
    const int src_width,
    const int channels,
    const int dest_height,
    const int dest_width,
    const float height_scale,
    const float width_scale,
    __half *dest)
{
    
    GRID_LOOP_X(i, threads)
    {
        int n = i;
        int c = n % channels;
        n /= channels;
        int dest_x = n % dest_width;
        n /= dest_width;
        int dest_y = n % dest_height;
        n /= dest_height;
        const __half *src_data_n = &src[n * channels * src_height * src_width];
        const int src_y = fminf((aligncorners) ? (roundf(dest_y * height_scale))
                                               : (floorf(dest_y * height_scale)),
                                src_height - 1);

        const int src_x = fminf((aligncorners) ? (roundf(dest_x * width_scale))
                                               : (floorf(dest_x * width_scale)),
                                src_width - 1);                 
        const int idx = (src_y * src_width + src_x) * channels + c;
        dest[i] = src_data_n[idx];
    }
}


#if __CUDA_ARCH__ >= 750 //might not work on other architectures. will probably work best with even tensors.
extern "C" __global__ void NearestNeighborNCHWBackFP16(
    const int aligncorners,
    const int threads,
    __half *src,
    const int src_height,
    const int src_width,
    const int channels,
    const int dest_height,
    const int dest_width,
    const float height_scale,
    const float width_scale,
    __half *dest)
{
    GRID_LOOP_X(i, threads)
    {
        int n = i;
        int src_x = n % src_width;
        n /= src_width;
        int src_y = n % src_height;
        n /= src_height;
        int c = n % channels;
        n /= channels;
        __half *src_data_n = &src[n * channels * src_height * src_width];
        const int dest_y = fminf((aligncorners) ? (roundf(src_y * height_scale))
                                                : (floorf(src_y * height_scale)),
                                 dest_height - 1);

        const int dest_x = fminf((aligncorners) ? (roundf(src_x * width_scale))
                                                : (floorf(src_x * width_scale)),
                                 dest_width - 1);
        const int idx = (c * dest_width * dest_height) + (dest_y * dest_width) + dest_x;
        atomicAdd(&src_data_n[idx], dest[i]);
    }
}
#else

//Might not work with archs that are not 7.5.. but might work best with even tensors.
extern "C" __global__ void NearestNeighborNCHWBackFP16(
    const int aligncorners,
    const int threads,
    __half *src,
    const int src_height,
    const int src_width,
    const int channels,
    const int dest_height,
    const int dest_width,
    const float height_scale,
    const float width_scale,
    __half *dest)
{
    
      const __half zer0= __float2half(0.0);
    GRID_LOOP_X(i, threads-1) //minus one because I do a conversion to half2 wich is 32bit to do the atomic add and don't want to run into space outside of array 
      
    {

        int n = i;
        int src_x = n % src_width;
        n /= src_width;
        int src_y = n % src_height;
        n /= src_height;
        int c = n % channels;
        n /= channels;
        __half *src_data_n = &src[n * channels * src_height * src_width];
        const int dest_y = fminf((aligncorners) ? (roundf(src_y * height_scale))
                                                : (floorf(src_y * height_scale)),
                                 dest_height - 1);

        const int dest_x = fminf((aligncorners) ? (roundf(src_x * width_scale))
                                                : (floorf(src_x * width_scale)),
                                 dest_width - 1);
        const int idx = (c * dest_width * dest_height) + (dest_y * dest_width) + dest_x;
        const __half2 dsth2 = __halves2half2(dest[i],zer0);   // This should give us the value half2[dest,0]
        void *vdptr=(void*)(&src_data_n[idx]);  //I don't know if I need to do this, but I work with go a lot and wanted to make sure it was going to step correctly
        __half2 *srch2hack = (__half2*)(vdptr); //Here say the void pointer address into srch2hack
        atomicAdd(srch2hack,dsth2); // this should be (src_data_n[idx]+dest[i], src_data_n[idx+1]+0)  //had to do threads -1 so in the last part we don't overstep the bounds
    }
    //This last part is to do the last value in dest.
     int n = threads-1;
        int src_x = n % src_width;
        n /= src_width;
        int src_y = n % src_height;
        n /= src_height;
        int c = n % channels;
        n /= channels;
        __half *src_data_n = &src[n * channels * src_height * src_width];
        const int dest_y = fminf((aligncorners) ? (roundf(src_y * height_scale))
                                                : (floorf(src_y * height_scale)),
                                 dest_height - 1);

        const int dest_x = fminf((aligncorners) ? (roundf(src_x * width_scale))
                                                : (floorf(src_x * width_scale)),
                                 dest_width - 1);
        const int idx = (c * dest_width * dest_height) + (dest_y * dest_width) + dest_x;
      src_data_n[idx] = __hadd(src_data_n[idx], dest[threads-1]);
}
#endif
extern "C" __global__ void AdaGradFP16(const int n,
                                        __half *w,   //w input and output
                                        __half *dw,        //input and will have to set to zero
                                        __half *gsum,      //storage
                                        const __half rate, //input
                                        const __half eps,
                                        const __half dwalpha)
{ //input
    StartAxis(stx,x)
    int n2=n/2;
    __half2 *w2=(__half2*)w,*dw2=(__half2*)dw,*gsum2=(__half2*)gsum;
    
    const __half2 rate2=__halves2half2(rate,rate);
    const __half2 eps2=__halves2half2(eps,eps);
    const __half2 dwalpha2=__halves2half2(dwalpha,dwalpha);
    GRID_LOOP_X(i, n2)
    {
        __half2 holder = gsum2[i];
        gsum2[i] = __hfma2(dw2[i],dw2[i],holder);
        w2[i] = __hadd2(-__h2div((__hmul2(rate2,dw2[i])) , (__hadd2(h2sqrt(gsum2[i]), eps2))),w2[i]);
        dw2[i] =__hmul2(dw2[i],dwalpha2);
    }
    if (stx==0 && (n%2)){
        __half holder = gsum[n-1];
        gsum[n-1] = __hfma(dw[n-1],dw[n-1],holder);
        w[n-1] = -__hdiv((__hmul(rate,dw[n-1])) , (__hadd(hsqrt(gsum[n-1]), eps)));
        dw[n-1] =__hmul(dw[n-1],dwalpha);
    }
}


//Need to fix this.
extern "C" __global__ void AdamFP16(const int n,
                                     __half *w,
                                     __half *gsum,
                                     __half *xsum,
                                     __half *dw,
                                     const __half rate,
                                     const __half beta1,
                                     const __half beta2,
                                     const __half eps,
                                     const __half denombeta1,
                                     const __half denombeta2,
                                     const __half dwalpha)
{
    int n2=n/2;
    __half2 *w2=(__half2*)w,*dw2=(__half2*)dw,*gsum2=(__half2*)gsum,*xsum2=(__half2*)xsum;
    const __half2 rate2=__halves2half2(rate,rate);
    const __half2 eps2=__halves2half2(eps,eps);
    const __half2 dwalpha2=__halves2half2(dwalpha,dwalpha);
    const __half2 beta12=__halves2half2(beta1,beta1);
    const __half2 beta22=__halves2half2(beta2,beta2);
     const __half one1 = __float2half(1.0);
  const __half2 one2=__halves2half2(one1,one1);
    StartAxis(stx,x)
    GRID_LOOP_X(i, n2)
    {
      gsum2[i] =__hfma2(__hsub2(one2,beta12),dw2[i],__hmul2(beta12,gsum2[i]));
     __half2 gsumt = __h2div(gsum2[i] ,__halves2half2(denombeta1,denombeta1));
      xsum2[i] = __hfma2(beta22 , xsum2[i], __hmul2(__hsub2(one2, beta22), __hmul2(dw2[i] , dw2[i])));
     __half2 xsumt = __h2div(xsum2[i] , __halves2half2(denombeta2,denombeta2));
     w2[i]=__hsub2(w2[i],__h2div(__hmul2(rate2,gsumt),__hadd2(h2sqrt(xsumt),eps2)));
     dw2[i]=  __hmul2(dwalpha2,dw2[i]);
    }
 
        if (stx==0 && (n%2)){
            const int i = n-1;
             gsum[i] =__hfma(__hsub(one1,beta1),dw[i],__hmul(beta1,gsum[i]));
            __half gsumt = __hdiv(gsum[i] ,denombeta1);
              xsum[i] = __hfma(beta2 , xsum[i], __hmul(__hsub(one1, beta2), __hmul(dw[i] , dw[i])));
             __half xsumt = __hdiv(xsum[i] , denombeta2);
             w[i]=__hsub(w[i],__hdiv(__hmul(rate,gsumt),__hadd(hsqrt(xsumt),eps)));
            dw[i]=  __hmul(dwalpha,dw[i]);
      }
}


extern "C" __global__ void AdaDeltaFP16(const int n,
                                         __half *w,   //weights input and output
                                         __half *gsum,      //storage
                                         __half *xsum,      //storage
                                         __half *dw,        //input and will have to set to zero
                                         const __half rate, //input
                                         const __half eps,
                                          const __half ro,
                                         const __half dwalpha)
{
    StartAxis(stx,x)
    int n2=n/2;
     __half2 *w2=(__half2*)w,*dw2=(__half2*)dw,*gsum2=(__half2*)gsum,*xsum2=(__half2*)xsum;
    const __half2 rate2=__halves2half2(rate,rate);
    const __half2 eps2=__halves2half2(eps,eps);
    const __half2 ro2=__halves2half2(ro,ro);
   const __half one1 = __float2half(1.0);
  const __half2 one2=__halves2half2(one1,one1);
    const __half2 dwalpha2=__halves2half2(dwalpha,dwalpha);
    GRID_LOOP_X(i, n2)
    {
       gsum2[i]= __hfma2(__hsub2(one2,ro2),__hmul2(dw2[i],dw2[i]),__hmul2(ro2,gsum2[i]));
       const __half2 dx2= __hmul2(h2sqrt(__h2div(__hadd2(xsum2[i],eps2),__hadd2(gsum2[i],eps2))),dw2[i]);
       xsum2[i]= __hfma2(__hsub2(one2,ro2),__hmul2(dx2,dx2),__hmul2(ro2,xsum2[i]));
       w2[i] =__hsub2(w2[i],dx2);
       dw2[i] =  __hmul2(dw2[i],dwalpha2);
    }
  
    if (stx ==0 &&(n%2)){
       int i = n-1;
       gsum[i]= __hfma(__hsub(one1,ro),__hmul(dw[i],dw[i]),__hmul(ro,gsum[i]));
       const __half dx= __hmul(hsqrt(__hdiv(__hadd(xsum[i],eps),__hadd(gsum[i],eps))),dw[i]);
       xsum[i]= __hfma(__hsub(one1,ro),__hmul(dx,dx),__hmul(ro,xsum[i]));
       w[i] =__hsub(w[i],dx);
       dw[i] =  __hmul(dw[i],dwalpha);
    }
}

#if __CUDA_ARCH__ >= 750
extern "C" __global__ void L1L2FP16(
    const int length,
    __half *dw,          //input and output
    const __half *w,     //input needs to ba an array
    __half *l1,          //output set to zero
    __half *l2,          //output set to zero
    const __half batch,  // should be an int but just send it as a float
    const __half decay1, //input
    const __half decay2)
{ //input
  const __half one1 = __float2half(1.0);
    const __half zero0 = __float2half(0);
    GRID_LOOP_X(i, length)
    {
        __half abs = w[i];
        if (__hlt(abs,zero0)){
            abs=-abs;
        }
        //atomicAdd(l1, abs(w[i]) * decay1);
        atomicAdd(l1,__hmul(abs,decay1));
        //atomicAdd(l2, (w[i] * w[i] * decay2) / 2.0);
        atomicAdd(l2, __hdiv(__hmul(__hmul(w[i] , w[i]) , decay2) , 2.0));
        //const float gradl1 = decay1 * (w[i] > 0 ? 1 : -1);
        const __half gradl1 = __hmul(decay1, (__hgt(w[i],zero0) ? one1 : -one1));
        //const float gradl2 = w[i] * decay2;
        const __half gradl2 = __hmul(w[i] ,decay2);
        //dw[i] = (dw[i] + gradl2 + gradl1) / batch;     
        dw[i] = __hdiv(__hadd(__hadd(dw[i], gradl2) , gradl1) , batch);
    }
}

#else
extern "C" __global__ void L1L2FP16(
    const int length,
    __half *dw,          //input and output
    const __half *w,     //input needs to ba an array
    __half *l1,          //output set to zero
    __half *l2,          //output set to zero
    const __half batch,  // should be an int but just send it as a float
    const __half decay1, //input
    const __half decay2)
{ //input
  const __half one1 = __float2half(1.0);
    const __half zero0 = __float2half(0);
    __shared__ __half2 *l1l2h2;
    __half2 *l1h2=&l1l2h2[0];
     __half2 *l2h2=&l1l2h2[1];
    GRID_LOOP_X(i, length)
    {
        __half abs = w[i];
        if (__hlt(abs,zero0)){
            abs=-abs;
        }
        //atomicAdd(l1, abs(w[i]) * decay1);
         const __half2 result= __halves2half2( __hmul(abs,decay1),zero0);
        atomicAdd(l1h2,result);
        //atomicAdd(l2, (w[i] * w[i] * decay2) / 2.0);
               const __half2 result2= __halves2half2(__hdiv(__hmul(__hmul(w[i] , w[i]) , decay2) , 2.0),zero0);
        atomicAdd(l2h2,result2 );
        //const float gradl1 = decay1 * (w[i] > 0 ? 1 : -1);
        const __half gradl1 = __hmul(decay1, (__hgt(w[i],zero0) ? one1 : -one1));
        //const float gradl2 = w[i] * decay2;
        const __half gradl2 = __hmul(w[i] ,decay2);
        //dw[i] = (dw[i] + gradl2 + gradl1) / batch;     
        dw[i] = __hdiv(__hadd(__hadd(dw[i], gradl2) , gradl1) , batch);
    }
    l1[0]=__low2half(l1h2[0]);
     l2[0]=__low2half(l2h2[0]);
}

#endif



extern "C" __global__ void ThreshForwardFP16(const int XThreads,
                                         const int batchsize,
                                         const __half *x,
                                         __half *y,
                                         const __half *negcoefs,
                                         const __half *threshhold,
                                         const __half *poscoefs)
{
    for (int i=0;i<batchsize;i++)
    {
        int stride=XThreads*i;
            GRID_LOOP_X(xIdx,XThreads)
            {
                if (__hgt(x[stride+xIdx],threshhold[xIdx]))
                {
                    y[stride+xIdx]=  __hmul(x[stride+xIdx],poscoefs[xIdx]);
                }
                else
                {
                    y[stride+xIdx]=   __hmul(negcoefs[xIdx],x[stride+xIdx]);
                }
            }
    }
}


extern "C" __global__ void ThreshBackwardFP16(const int XThreads,
                                          const int batchsize,
                                          const __half *x,
                                          __half *dx,
                                          const __half *dy,
                                          const __half *negcoefs,
                                          __half *dnegcoefs,
                                          const __half *threshhold,
                                          const __half *poscoefs,
                                          __half *dposcoefs)
{
    for (int i=0;i<batchsize;i++)
    {
        int stride=XThreads*i;
            GRID_LOOP_X(xIdx,XThreads)
            {
                if (__hgt(x[stride+xIdx],threshhold[xIdx]))
                {
                 //  dx[stride+xIdx]=  poscoefs[xIdx]*dy[stride+xIdx];
                 dx[stride+xIdx]=__hmul(dy[stride+xIdx],poscoefs[xIdx]);
                 // dposcoefs[xIdx]+=dy[xIdx]*x[stride+xIdx];
                 dposcoefs[xIdx]=__hfma(dy[xIdx],x[stride+xIdx],dposcoefs[xIdx]);
                }
                else
                {
                  // dx[stride+xIdx]=  negcoefs[xIdx]*dy[stride+xIdx];
                  dx[stride+xIdx]= __hmul(dy[stride+xIdx],negcoefs[xIdx]);
                  // dnegcoefs[xIdx]+=dy[xIdx]*x[stride+xIdx];
                  dnegcoefs[xIdx]=__hfma(dy[xIdx],x[stride+xIdx],dnegcoefs[xIdx]);
                }
            }
    }
}

extern "C" __global__ void PreluForwardFP16(const int XThreads,
                                        const int batchsize,
                                        const __half *x,
                                        __half *y,
                                        const __half *coefs)
{
  
    for (int i=0;i<batchsize;i++)
    {
        int stride=XThreads*i;
            GRID_LOOP_X(xIdx,XThreads)
            {
                if (__hgt(x[stride+xIdx],0))
                {
                    y[stride+xIdx]=  x[stride+xIdx];
                }
                else
                {
                    y[stride+xIdx]=  __hmul(coefs[xIdx],x[stride+xIdx]);
                }
            }
    }
   
}    

extern "C" __global__ void PreluBackwardFP16(const int XThreads,
                                                          const int batchsize,
                                                          __half *dx,
                                                          const __half *x,
                                                          const __half *dy,
                                                          const __half *coefs,
                                                          __half *dcoefs)
{
        const __half zero0 = __float2half(0);
    for (int i=0;i<batchsize;i++)
    {
        int stride=XThreads*i;
            GRID_LOOP_X(xIdx,XThreads)
            {
               if (__hgt(x[stride+xIdx],zero0))
                {
                    dx[stride+xIdx]=  dy[stride+xIdx];
                }
                else
                {
                 //  dx[stride+xIdx]=  coefs[xIdx]*dy[stride+xIdx];
                  dx[stride+xIdx]=  __hmul(coefs[xIdx],dy[stride+xIdx]);
                 // dcoefs[xIdx]+=dy[xIdx]*x[stride+xIdx];
                 dcoefs[xIdx]=__hfma(dy[xIdx],x[stride+xIdx],dcoefs[xIdx]);
                }
            }
    }
}
extern "C" __global__ void LeakyForwardAlphaBetaFP16(const int length,
                                             const __half *x,
                                             __half *y,
                                             const __half coef,
                                             const __half alpha,
                                              const __half beta)
{
        const __half zero0 = __float2half(0);
    GRID_LOOP_X(i, length)
    {
       
      if (__hgt(x[i],zero0))
        {
            // y[i] = (beta*y[i]) + (alpha *x[i]) ;
            y[i]=__hadd(__hmul(beta,y[i]),__hmul(alpha,x[i]));
        }
        else
        {
         //y[i] = (beta*previous) + (alpha *x[i]*coef);
         y[i]=__hadd(__hmul(beta,y[i]),__hmul(alpha,__hmul(x[i],coef)));
        }
          __syncthreads();
    }
}
extern "C" __global__ void LeakyBackwardAlphaBetaFP16(const int length,
                                              const __half *x,
                                              __half *dx,
                                              const __half *dy,
                                              const __half coef,
                                              const __half alpha,
                                              const __half beta)
{
    const __half zero0 = __float2half(0);
    GRID_LOOP_X(i, length)
    {
  
        if (__hgt(x[i],zero0))
        {
             // dx[i] =(beta *dx[i]) + (dy[i] * alpha);
              dx[i]=__hadd(__hmul(beta,dy[i]),__hmul(alpha,dx[i]));
        }
        else
        {
             // dx[i] = (beta *dx[i]) + (dy[i]*coef * alpha);
             dx[i]=__hadd(__hmul(beta,dx[i]),__hmul(alpha,__hmul(dy[i],coef)));
        }
        __syncthreads();
    }
}
extern "C" __global__ void LeakyForwardAlphaFP16(const int length,
                                             const __half *x,
                                             __half *y,
                                             const __half coef,
                                             const __half alpha)
{
    const __half zero0 = __float2half(0);
    GRID_LOOP_X(i, length)
    {
        
      if (__hgt(x[i],zero0))
        {
            y[i] = __hmul(alpha ,x[i]);
        }
        else
        {
        
            y[i] =__hmul(__hmul(x[i],coef) , alpha);
        }
         __syncthreads();
    }
}


extern "C" __global__ void LeakyBackwardAlphaFP16(const int length,
                                              const __half *x,
                                              __half *dx,
                                              const __half *dy,
                                              const __half coef,
                                              const __half alpha)
{
        const __half zero0 = __float2half(0);
 
    GRID_LOOP_X(i, length)
    {

        if  (__hgt(x[i],zero0))
        {
           // dx[i] = dy[i]*alpha;
            dx[i] = __hmul(alpha ,dy[i]);
        }
        else
        {
             // dx[i] = dy[i]*coef *alpha;
             dx[i] =__hmul(__hmul(dy[i],coef) , alpha);
        }
         __syncthreads();
    }
}

extern "C" __global__ void LeakyForwardFP16(const int length,
                                             const __half *x,
                                             __half *y,
                                             const __half coef)
{
        const __half zero0 = __float2half(0);
    GRID_LOOP_X(i, length)
    {
       if  (__hgt(x[i],zero0))
        {
            y[i] = x[i];
        }
        else
        {
         //   y[i] = x[i] * coef;
       y[i]= __hmul( x[i] , coef);
        }
    }
}

extern "C" __global__ void LeakyBackwardFP16(const int length,
                                              const __half *x,
                                              __half *dx,
                                              const __half *dy,
                                              const __half coef)
{
    const __half zero0 = __float2half(0);
    GRID_LOOP_X(i, length)
    {

         if  (__hgt(x[i],zero0))
        {
            dx[i] = dy[i];
        }
        else
        {
//       dx[i] = dy[i] * coef;
         dx[i]= __hmul( dy[i] , coef);
        }
    }
}


#if __CUDA_ARCH__ >= 750
extern "C" __global__ void MSELossbyBatchesFP16(const int xthreads,
const int ythreads,
 __half *errors, 
 const __half *target, 
 const __half *networkout, 
 __half *loss)
{
  const __half htwo= __float2half(2.0);
    GRID_AXIS_LOOP(xIdx,xthreads,x)
    {
        const int i=ythreads*xIdx;
            GRID_AXIS_LOOP(yIdx, ythreads,y)
            {  
                const __half y = __hsub(networkout[i] , target[i]);
        errors[i] = y;
             atomicAdd(&loss[xIdx], __hdiv(__hmul(y , y) , htwo));
            }
    }
}
extern "C" __global__ void MSELossFP16(const int n, 
                            __half *errors, 
                            const __half *target,
                            const __half *networkout, 
                            __half *loss,
                            const __half alpha,
                            const __half beta)
{
    StartAxis(stx,x)
    int n2=n/2;
     __half2 *errors2=(__half2*)errors, *target2=(__half2*)target, *networkout2=(__half2*)networkout, *loss2=(__half2*)loss;
 //  const __half2 alpha2=__halves2half2(alpha), beta2=__halves2half2(beta);
    const __half2 htwo2=__halves2half2(__float2half(2.0),__float2half(2.0));
     const __half htwo= __float2half(2.0);
    loss[0]=0;
    GRID_LOOP_X(i, n2)
    {
        const __half2 y = __hsub2(networkout2[i] , target2[i]);
        errors2[i] = y;
        atomicAdd(loss2, __h2div(__hmul2(y , y) ,htwo2));
    }
    if (stx==0 && (n%2)){
       const int i=n-1;
        const __half y = __hsub(networkout[i] , target[i]);
        errors[i] = y;
        atomicAdd(loss, __hdiv(__hmul(y , y) , htwo));
    }
      

   
}
#else  
extern "C" __global__ void MSELossbyBatchesFP16(
const int xthreads,
const int batches,
 __half2 *errors, 
 const __half2 *target, 
 const __half2 *networkout, 
 __half *loss)
{
  const __half htwo= __float2half(2.0);
  const __half2 htwo2 =__halves2half2(htwo,htwo);
  const int n=xthreads/2;
  __shared__ __half2 *loss2;
  for (int i=0; i<batches;i++){
      loss2[i]=__floats2half2_rn(0.0,0.0);
 GRID_AXIS_LOOP(xIdx,n,x)
    {
       const __half2 y = __hsub2(networkout[i*n+xIdx] , target[i*n+xIdx]);
       errors[i] = y;
       atomicAdd(&loss2[i], __h2div(__hmul2(y , y) , htwo2));
    }
  loss[i]=__hadd(__low2half(loss2[i]),__high2half(loss2[i]));
  }
   
}
extern "C" __global__ void MSELossFP16(const int n, 
                            __half2 *errors, 
                            const __half2 *target,
                            const __half2 *networkout, 
                            __half *loss,
                            const __half alpha,
                            const __half beta)
{
//    StartAxis(stx,x)
    int n2=n/2;
 //  const __half2 alpha2=__halves2half2(alpha), beta2=__halves2half2(beta);
    const __half2 htwo2=__halves2half2(__float2half(2.0),__float2half(2.0));
   //  const __half htwo= __float2half(2.0);
      __shared__ __half2 *loss2;
      loss2[0]= __halves2half2(__float2half(0.0),__float2half(0.0));
   
    GRID_LOOP_X(i, n2)
    {
        const __half2 y = __hsub2(networkout[i] , target[i]);
        errors[i] = y;
        atomicAdd(loss2, __h2div(__hmul2(y , y) ,htwo2));
    }
    loss[0]=__hadd(__low2half(loss2[0]),__high2half(loss2[0]));
    
}
#endif
/*
extern "C" __global__ void SoftMaxErrAndLoss(const int xthreads, const int ntargets, const float *target, const float *softmaxoutput, float *loss, float * inputerrors){
    const float fntargets=(float)(ntargets);
    GRID_LOOP_X(xIdx,xthreads){
        if (target[xIdx]>0){
            atomicAdd(&loss[xIdx],-log10(softmaxoutput[xIdx]/fntargets));
        }
    }
}
*/
extern "C" __global__ void SoftMaxAverageLoss(const int xthreads, const int ntargets, const float *target, const float *softmaxoutput, float *loss){
     const float fntargets = (float)(ntargets);
    GRID_LOOP_X(xIdx,xthreads){
        if (target[xIdx]>0){
            atomicAdd(&loss[0],-log10(softmaxoutput[xIdx])/fntargets);
        }
    }
}
/*
extern "C" __global__ void SoftMaxLossPerBatch(const int xthreads,const int ythreads, const int ntargetsperbatch,  const float *target, const float *softmaxoutput,float *loss)
{
    const float npbtargs = (float)(ntargetsperbatch);
    GRID_AXIS_LOOP(xIdx,xthreads,x)
    {       
            const int offset=ythreads*xIdx;
            GRID_AXIS_LOOP(yIdx, ythreads,y)
            {  
                if (target[offset+yIdx]>0){
                    atomicAdd(&loss[xIdx],-log10(softmaxoutput[offset+yIdx])/npbtargs);
                }
            
            }
    }
}
*/

/*
#if __CUDA_ARCH__ >= 750
extern "C" __global__ void MSELossbyBatchesFP16(const int xthreads,
const int ythreads,
 __half *errors, 
 const __half *target, 
 const __half *networkout, 
 __half *loss)
{
  const __half htwo= __float2half(2.0);
    GRID_AXIS_LOOP(xIdx,xthreads,x)
    {
        const int i=ythreads*xIdx;
            GRID_AXIS_LOOP(yIdx, ythreads,y)
            {  
                const __half y = __hsub(networkout[i] , target[i]);
        errors[i] = y;
             atomicAdd(&loss[xIdx], __hdiv(__hmul(y , y) , htwo));
            }
    }
}
extern "C" __global__ void MSELossFP16(const int n, 
                            __half *errors, 
                            const __half *target,
                            const __half *networkout, 
                            __half *loss,
                            const __half alpha,
                            const __half beta)
{
    StartAxis(stx,x)
    int n2=n/2;
     __half2 *errors2=(__half2*)errors, *target2=(__half2*)target, *networkout2=(__half2*)networkout, *loss2=(__half2*)loss;
 //  const __half2 alpha2=__halves2half2(alpha), beta2=__halves2half2(beta);
    const __half2 htwo2=__halves2half2(__float2half(2.0),__float2half(2.0));
     const __half htwo= __float2half(2.0);
    loss[0]=0;
    GRID_LOOP_X(i, n2)
    {
        const __half2 y = __hsub2(networkout2[i] , target2[i]);
        errors2[i] = y;
        atomicAdd(loss2, __h2div(__hmul2(y , y) ,htwo2));
    }
    if (stx==0 && (n%2)){
       const int i=n-1;
        const __half y = __hsub(networkout[i] , target[i]);
        errors[i] = y;
        atomicAdd(loss, __hdiv(__hmul(y , y) , htwo));
    }
      

   
}
#else  
extern "C" __global__ void MSELossbyBatchesFP16(
const int xthreads,
const int batches,
 __half2 *errors, 
 const __half2 *target, 
 const __half2 *networkout, 
 __half *loss)
{
  const __half htwo= __float2half(2.0);
  const __half2 htwo2 =__halves2half2(htwo,htwo);
  const int n=xthreads/2;
  __shared__ __half2 *loss2;
  for (int i=0; i<batches;i++){
      loss2[i]=__floats2half2_rn(0.0,0.0);
 GRID_AXIS_LOOP(xIdx,n,x)
    {
       const __half2 y = __hsub2(networkout[i*n+xIdx] , target[i*n+xIdx]);
       errors[i] = y;
       atomicAdd(&loss2[i], __h2div(__hmul2(y , y) , htwo2));
    }
  loss[i]=__hadd(__low2half(loss2[i]),__high2half(loss2[i]));
  }
   
}
extern "C" __global__ void MSELossFP16(const int n, 
                            __half2 *errors, 
                            const __half2 *target,
                            const __half2 *networkout, 
                            __half *loss,
                            const __half alpha,
                            const __half beta)
{
//    StartAxis(stx,x)
    int n2=n/2;
 //  const __half2 alpha2=__halves2half2(alpha), beta2=__halves2half2(beta);
    const __half2 htwo2=__halves2half2(__float2half(2.0),__float2half(2.0));
   //  const __half htwo= __float2half(2.0);
      __shared__ __half2 *loss2;
      loss2[0]= __halves2half2(__float2half(0.0),__float2half(0.0));
   
    GRID_LOOP_X(i, n2)
    {
        const __half2 y = __hsub2(networkout[i] , target[i]);
        errors[i] = y;
        atomicAdd(loss2, __h2div(__hmul2(y , y) ,htwo2));
    }
    loss[0]=__hadd(__low2half(loss2[0]),__high2half(loss2[0]));
    
}
#endif
*/