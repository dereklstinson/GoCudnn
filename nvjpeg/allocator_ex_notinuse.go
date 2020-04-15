package nvjpeg

/*
#include <nvjpeg.h>

#include<cuda_runtime_api.h>

//int dev_malloc(void **p,size_t s) {
//	return (int)cudaMallocManaged(p,s,cudaMemAttachGlobal);
//}
//
//int dev_free(void *p) { return (int)cudaFree(p); }
//
//int host_malloc(void **p,size_t s,unsigned int flags){
//	return (int)cudaMallocManaged(p,s,cudaMemAttachHost);
//}
//int host_free(void *p) { return (int)cudaFree(p); }
//
//void filldevvales(nvjpegDevAllocator_t *devalloc){
//	devalloc->dev_malloc=&dev_malloc;
//	devalloc->dev_free=&dev_free;
//
//}
//void fillhostvales(nvjpegPinnedAllocator_t *devalloc){
//	devalloc->pinned_malloc=&host_malloc;
//	devalloc->pinned_free=&host_free;
//
//}
*/
//import "C"

/*
//CreateEx uses cudaMallocManaged. The handle is used for all consecutive nvjpeg calls
// IN         backend       : Backend to use. Currently Default or Hybrid (which is the same at the moment) is supported.
// INT/OUT    handle        : Codec instance, use for other calls
func CreateEx(backend Backend) (h *Handle, err error) {
	h = new(Handle)
	deval := new(C.nvjpegDevAllocator_t)
	pindal := new(C.nvjpegPinnedAllocator_t)
	C.filldevvales(deval)
	C.fillhostvales(pindal)
	//deval.dev_malloc = C.dev_malloc
	//deval.dev_free = C.dev_free
	err = status(C.nvjpegCreateEx(backend.c(), deval, pindal, 0, &h.h)).error()
	return h, err
}


func CreateEx(backend Backend, dev *DevAllocator, pin *PinnedAllocator, flags uint32) (*Handle, error) {
	h := new(Handle)
	err := status(C.nvjpegCreateEx(backend.c(), dev.cptr(), pin.cptr(), (C.uint)(flags), &h.h)).error()
	if err != nil {
		return nil, err
	}
	runtime.SetFinalizer(h, nvjpegDestroy)
	return h, err
}

//DevAllocator - Memory allocator using mentioned prototypes, provided to nvjpegCreate
// This allocator will be used for all device memory allocations inside library
// In any way library is doing smart allocations (reallocates memory only if needed)
type DevAllocator struct {
	da C.nvjpegDevAllocator_t
}

func (d *DevAllocator) cptr() *C.nvjpegDevAllocator_t {
	return &d.da
}
func (d DevAllocator) c() C.nvjpegDevAllocator_t {
	return d.da
}

//PinnedAllocator will wrap a pinned allocator.
type PinnedAllocator struct {
	pa C.nvjpegPinnedAllocator_t
}

func (p *PinnedAllocator) cptr() *C.nvjpegPinnedAllocator_t {
	return &p.pa
}
func (p PinnedAllocator) c() C.nvjpegPinnedAllocator_t {
	return p.pa
}



*/
/*
//Backend are flags that are used to set the implimentation.
type Backend C.nvjpegBackend_t

func (b Backend) c() C.nvjpegBackend_t {
	return C.nvjpegBackend_t(b)
}

//Default defaults to GPUHybrid ---  Backend(C.NVJPEG_BACKEND_DEFAULT)  //binder note. I don't know why this is here.
//Method changes the underlying value of the flag and also returns that value.
func (b *Backend) Default() Backend {
	*b = Backend(C.NVJPEG_BACKEND_DEFAULT)
	return *b
}

//Hybrid uses CPU for Huffman decode ---  Backend(C.NVJPEG_BACKEND_HYBRID)
//Method changes the underlying value of the flag and also returns that value.
func (b *Backend) Hybrid() Backend {
	*b = Backend(C.NVJPEG_BACKEND_HYBRID)
	return *b
}

//GPUHybrid nvjpegDecodeBatched will use GPU decoding for baseline JPEG images
//with interleaved scan when batch size is bigger than 100,  it uses CPU for other JPEG types.
//Other decode APIs will continue to use CPU for Huffman decode
//Method changes the underlying value of the flag and also returns that value.
func (b *Backend) GPUHybrid() Backend {
	*b = Backend(C.NVJPEG_BACKEND_GPU_HYBRID)
	return *b
}
*/
