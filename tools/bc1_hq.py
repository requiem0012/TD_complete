"""BC1 endpoint refinement with an exact decoded-RGB error acceptance guard.

Original encoder output is always a candidate, including 3-color blocks.
PCA/minmax seeds and alternating least-squares endpoint/index fitting are
accepted per block only when decoded integer RGB squared error decreases.
This optimizes a measurable objective; it cannot promise universal perception.
"""
import numpy as np

def blocks_from_image(image):
    a=np.asarray(image.convert("RGB"),dtype=np.int32)
    h,w=a.shape[:2]
    if w%4 or h%4:
        raise ValueError("BC1 dimensions must be multiples of 4")
    return a.reshape(h//4,4,w//4,4,3).transpose(0,2,1,3,4).reshape(-1,16,3)

def expand(c):
    c=np.asarray(c,dtype=np.uint32)
    r,g,b=c>>11,(c>>5)&63,c&31
    return np.stack(((r<<3)|(r>>2),(g<<2)|(g>>4),(b<<3)|(b>>2)),axis=-1).astype(np.int32)

def palette(c0,c1):
    a,b=expand(c0),expand(c1)
    four=(c0>c1)[:,None]
    return np.stack((a,b,np.where(four,(2*a+b)//3,(a+b)//2),
                     np.where(four,(a+2*b)//3,0)),axis=1)

def unpack(data):
    words=np.frombuffer(data,dtype="<u8")
    c0=(words&65535).astype(np.uint32)
    c1=((words>>16)&65535).astype(np.uint32)
    idx=((words[:,None]>>np.arange(32,64,2,dtype=np.uint64))&3).astype(np.uint8)
    return c0,c1,idx

def decoded_blocks(data):
    c0,c1,idx=unpack(data)
    return palette(c0,c1)[np.arange(len(c0))[:,None],idx]

def pack(c0,c1,idx):
    indices=np.sum(idx.astype(np.uint64)<<np.arange(32,64,2,dtype=np.uint64),axis=1,dtype=np.uint64)
    words=c0.astype(np.uint64)|(c1.astype(np.uint64)<<16)|indices
    return words.astype("<u8").tobytes()

def _quantize(v):
    q=np.rint(np.clip(v,0,255)*np.array([31,63,31],dtype=np.float32)/255).astype(np.uint32)
    return (q[:,0]<<11)|(q[:,1]<<5)|q[:,2]

def _ordered(a,b):
    hi,lo=np.maximum(a,b).copy(),np.minimum(a,b).copy()
    same=hi==lo
    hi[same & (lo<65535)]+=1
    lo[same & (hi==65535)]=np.minimum(lo[same & (hi==65535)],65534)
    return hi,lo

def refine_bc1(image,baseline,iterations=8,return_stats=False):
    pix=blocks_from_image(image)
    count=len(pix)
    if len(baseline)!=count*8:
        raise ValueError("BC1 size mismatch")
    original0,original1,original_idx=unpack(baseline)
    best0,best1,best_idx=original0.copy(),original1.copy(),original_idx.copy()
    original_error=np.square(pix-decoded_blocks(baseline),dtype=np.int32).sum(axis=(1,2))
    best_error=original_error.copy()
    def evaluate(c0,c1):
        pal=palette(c0,c1)
        distances=np.square(pix[:,:,None,:]-pal[:,None,:,:],dtype=np.int32).sum(axis=3)
        idx=distances.argmin(axis=2).astype(np.uint8)
        error=np.take_along_axis(distances,idx[:,:,None],axis=2).sum(axis=(1,2))
        improved=error<best_error
        best_error[improved]=error[improved]
        best0[improved]=c0[improved];best1[improved]=c1[improved];best_idx[improved]=idx[improved]
        return idx
    evaluate(original0,original1)
    centered=pix.astype(np.float32)-pix.mean(axis=1,keepdims=True)
    cov=np.einsum("bni,bnj->bij",centered,centered)
    axis=np.eye(3,dtype=np.float32)[np.diagonal(cov,axis1=1,axis2=2).argmax(axis=1)]
    for _ in range(6):
        axis=np.einsum("bij,bj->bi",cov,axis)
        axis/=np.maximum(np.linalg.norm(axis,axis=1,keepdims=True),1e-8)
    projections=np.einsum("bni,bi->bn",centered,axis)
    rows=np.arange(count)
    seeds=[(original0,original1),
           (_quantize(pix[rows,projections.argmax(axis=1)]),_quantize(pix[rows,projections.argmin(axis=1)])),
           (_quantize(pix.max(axis=1)),_quantize(pix.min(axis=1)))]
    av=np.array([3,0,2,1],dtype=np.float32);bv=3-av
    for a,b in seeds:
        c0,c1=_ordered(a,b)
        for _ in range(iterations):
            idx=evaluate(c0,c1)
            wa,wb=av[idx],bv[idx]
            aa=(wa*wa).sum(axis=1);ab=(wa*wb).sum(axis=1);bb=(wb*wb).sum(axis=1)
            ap=np.einsum("bn,bnc->bc",wa,pix)*3;bp=np.einsum("bn,bnc->bc",wb,pix)*3
            det=aa*bb-ab*ab
            valid=det>1e-8;den=np.maximum(det,1e-8)[:,None]
            e0=np.where(valid[:,None],(ap*bb[:,None]-bp*ab[:,None])/den,expand(c0))
            e1=np.where(valid[:,None],(bp*aa[:,None]-ap*ab[:,None])/den,expand(c1))
            c0,c1=_ordered(_quantize(e0),_quantize(e1))
        evaluate(c0,c1)
    result=pack(best0,best1,best_idx)
    # Final independent acceptance audit; never replace the baseline on regressions.
    final_error=np.square(pix-decoded_blocks(result),dtype=np.int32).sum(axis=(1,2))
    if np.any(final_error>original_error):
        raise AssertionError("BC1 refinement quality guard failed")
    if not return_stats:
        return result
    return result,dict(blocks=count,improved_blocks=int(np.count_nonzero(final_error<original_error)),
                       baseline_sse=int(original_error.sum()),hq_sse=int(final_error.sum()),
                       max_block_error_increase=int((final_error-original_error).max()))
