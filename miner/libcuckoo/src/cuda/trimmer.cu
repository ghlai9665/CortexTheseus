#include <time.h>

#include "trimmer.h" 
namespace cuckoogpu {

#define TROMP_SEEDA
#define TROMP_SEEDB
#define TROMP_ROUND
#define TROMP_TAIL

//#define TIMER

#define DUCK_A_EDGES (EDGES_A)
#define DUCK_A_EDGES_NX (DUCK_A_EDGES * NX)
#define DUCK_B_EDGES (EDGES_B)
#define DUCK_B_EDGES_NX (DUCK_B_EDGES * NX)

__device__ ulonglong4 Pack4edges(const uint2 e1, const  uint2 e2, const  uint2 e3, const  uint2 e4)
{
	u64 r1 = (((u64)e1.y << 32) | ((u64)e1.x));
	u64 r2 = (((u64)e2.y << 32) | ((u64)e2.x));
	u64 r3 = (((u64)e3.y << 32) | ((u64)e3.x));
	u64 r4 = (((u64)e4.y << 32) | ((u64)e4.x));
	return make_ulonglong4(r1, r2, r3, r4);
}

__device__ node_t dipnode(const siphash_keys &keys, edge_t nce, u32 uorv) {
  u64 nonce = 2*nce + uorv;
  u64 v0 = keys.k0, v1 = keys.k1, v2 = keys.k2, v3 = keys.k3^ nonce;
  SIPROUND; SIPROUND;
  v0 ^= nonce;
  v2 ^= 0xff;
  SIPROUND; SIPROUND; SIPROUND; SIPROUND;
  return (v0 ^ v1 ^ v2  ^ v3) & EDGEMASK;
}

// ===== Above =======

__device__ __forceinline__  void Increase2bCounter(u32 *ecounters, const int bucket) {
  int word = bucket >> 5;
  unsigned char bit = bucket & 0x1F;
  u32 mask = 1 << bit;

  u32 old = atomicOr(ecounters + word, mask) & mask;
  if (old)
    atomicOr(ecounters + word + NZ/32, mask);
}

__device__ __forceinline__  bool Read2bCounter(u32 *ecounters, const int bucket) {
  int word = bucket >> 5;
  unsigned char bit = bucket & 0x1F;
  u32 mask = 1 << bit;

  return (ecounters[word + NZ/32] & mask) != 0;
}


    __device__ bool null(u32 nonce) {
        return nonce == 0;
    }

    __device__ bool null(uint2 nodes) {
        return nodes.x == 0 && nodes.y == 0;
    }


__device__ u64 dipblock(const siphash_keys &keys, const edge_t edge, u64 *buf) {
  //diphash_state shs(keys);
  
  u64 v0 = keys.k0, v1 = keys.k1, v2 = keys.k2, v3 = keys.k3;

  edge_t edge0 = edge & ~EDGE_BLOCK_MASK;
  u32 i;
  for (i=0; i < EDGE_BLOCK_MASK; i++) {
    //shs.hash24(edge0 + i);
	  edge_t nonce = edge0 + i;
	v3^=nonce;
	SIPROUND; SIPROUND;
	v0 ^= nonce;
	v2 ^= 0xff;	
	SIPROUND; SIPROUND; SIPROUND; SIPROUND;

//    buf[i] = shs.xor_lanes();
	buf[i] = (v0 ^ v1) ^ (v2  ^ v3);
  }
//  shs.hash24(edge0 + i);
	  edge_t nonce = edge0 + i;
    v3^=nonce;
  SIPROUND; SIPROUND;
  v0 ^= nonce;
  v2 ^= 0xff;
  SIPROUND; SIPROUND; SIPROUND; SIPROUND;

//    buf[i] = shs.xor_lanes();
  buf[i] = 0;
  //return shs.xor_lanes();
  return (v0 ^ v1) ^ (v2  ^ v3);
}

__device__ u32 endpoint(uint2 nodes, int uorv) {
  return uorv ? nodes.y : nodes.x;
}

__constant__ uint2 recoveredges[PROOFSIZE];


__global__ void Cuckaroo_Recovery(const siphash_keys &sipkeys, ulonglong4 *buffer, int *indexes) {
  const int gid = blockDim.x * blockIdx.x + threadIdx.x;
  const int lid = threadIdx.x;
  const int nthreads = blockDim.x * gridDim.x;
  const int loops = NEDGES / nthreads;
  __shared__ u32 nonces[PROOFSIZE];
  u64 buf[EDGE_BLOCK_SIZE];

  if (lid < PROOFSIZE) nonces[lid] = 0;
  __syncthreads();
  for (int blk = 0; blk < loops; blk += EDGE_BLOCK_SIZE) {
    u32 nonce0 = gid * loops + blk;
    const u64 last = dipblock(sipkeys, nonce0, buf);
    for (int i = 0; i < EDGE_BLOCK_SIZE; i++) {
      u64 edge = buf[i] ^ last;
      u32 u = edge & EDGEMASK;
      u32 v = (edge >> 32) & EDGEMASK;
      for (int p = 0; p < PROOFSIZE; p++) {
        if (recoveredges[p].x == u && recoveredges[p].y == v)
          nonces[p] = nonce0 + i;
      }
    }
  }
  __syncthreads();
  if (lid < PROOFSIZE) {
    if (nonces[lid] > 0)
      indexes[lid] = nonces[lid];
  }
}

__global__ void Cuckoo_Recovery(const siphash_keys &sipkeys, ulonglong4 *buffer, int *indexes) {
  const int gid = blockDim.x * blockIdx.x + threadIdx.x;
  const int lid = threadIdx.x;
  const int nthreads = blockDim.x * gridDim.x;
  const int loops = NEDGES / nthreads;
  __shared__ u32 nonces[PROOFSIZE];

  if (lid < PROOFSIZE) nonces[lid] = 0;
  __syncthreads();
  for (int i = 0; i < loops; i++) {
	u64 nonce = gid * loops + i;
	u64 u = dipnode(sipkeys, nonce, 0);
	u64 v = dipnode(sipkeys, nonce, 1);
	for (int i = 0; i < PROOFSIZE; i++) {
	  if (recoveredges[i].x == u && recoveredges[i].y == v)
		nonces[i] = nonce;
	}
  }
  __syncthreads();
  if (lid < PROOFSIZE) {
	if (nonces[lid] > 0)
	  indexes[lid] = nonces[lid];
  }
}


#ifndef FLUSHA // should perhaps be in trimparams and passed as template parameter
#define FLUSHA 16
#endif

template<int maxOut>
__global__ void Cuckaroo_SeedA(const siphash_keys &sipkeys, uint2 * __restrict__ buffer, int * __restrict__ indexes) {
  const int group = blockIdx.x;
  const int dim = blockDim.x;
  const int lid = threadIdx.x;
  const int gid = group * dim + lid;
  const int nthreads = gridDim.x * dim;
  const int FLUSHA2 = 2*FLUSHA;

  __shared__ uint2 tmp[NX][FLUSHA2]; // needs to be ulonglong4 aligned
  __shared__ int counters[NX];
  u64 buf[EDGE_BLOCK_SIZE];

  for (int row = lid; row < NX; row += dim)
    counters[row] = 0;
  __syncthreads();

  const int col = group % NX;
  const int loops = NEDGES / nthreads; // assuming THREADS_HAVE_EDGES checked
  for (int blk = 0; blk < loops; blk += EDGE_BLOCK_SIZE) {
    u32 nonce0 = gid * loops + blk;
    const u64 last = dipblock(sipkeys, nonce0, buf);
    for (u32 e = 0; e < EDGE_BLOCK_SIZE; e++) {
      u64 edge = buf[e] ^ last;
      u32 node0 = edge & EDGEMASK;
      u32 node1 = (edge >> 32) & EDGEMASK;
      int row = node0 >> YZBITS;
      int counter = min((int)atomicAdd(counters + row, 1), (int)(FLUSHA2-1)); // assuming ROWS_LIMIT_LOSSES checked
      tmp[row][counter] = make_uint2(node0, node1);
      __syncthreads();
      if (counter == FLUSHA-1) {
        int localIdx = min(FLUSHA2, counters[row]);
        int newCount = localIdx % FLUSHA;
        int nflush = localIdx - newCount;
        int cnt = min((int)atomicAdd(indexes + row * NX + col, nflush), (int)(maxOut - nflush));
        for (int i = 0; i < nflush; i += 1)
          buffer[((u64)(row * NX + col) * maxOut + cnt + i)] = tmp[row][i];
        for (int t = 0; t < newCount; t++) {
          tmp[row][t] = tmp[row][t + nflush];
        }
        counters[row] = newCount;
      }
      __syncthreads();
    }
  }
  uint2 zero = make_uint2(0, 0);
  for (int row = lid; row < NX; row += dim) {
    int localIdx = min(FLUSHA2, counters[row]);
    int cnt = min((int)atomicAdd(indexes + row * NX + col, localIdx), (int)(maxOut - localIdx));
    for (int i = 0; i < localIdx; i += 1) {
      buffer[((u64)(row * NX + col) * maxOut + cnt + i)] = tmp[row][i];
    }
  }
}
	template<int maxOut, typename EdgeOut>
		__global__ void Cuckoo_SeedA(const siphash_keys &sipkeys, EdgeOut * __restrict__ buffer, int * __restrict__ indexes) {
			const int group = blockIdx.x;
			const int dim = blockDim.x;
			const int lid = threadIdx.x;
			const int gid = group * dim + lid;
			const int nthreads = gridDim.x * dim;
			const int FLUSHA2 = 2*FLUSHA;

			__shared__ EdgeOut tmp[NX][FLUSHA2]; // needs to be ulonglong4 aligned
			__shared__ int counters[NX];

			for (int row = lid; row < NX; row += dim)
				counters[row] = 0;
			__syncthreads();

			const int col = group % NX;
			const int loops = NEDGES / nthreads;
			for (int i = 0; i < loops; i++) {
				u32 nonce = gid * loops + i;
				u32 node1, node0 = dipnode(sipkeys, (u64)nonce, 0);
				if (sizeof(EdgeOut) == sizeof(uint2))
					node1 = dipnode(sipkeys, (u64)nonce, 1);
				int row = node0 >> YZBITS;
				int counter = min((int)atomicAdd(counters + row, 1), (int)(FLUSHA2-1));
				tmp[row][counter] = make_Edge(nonce, tmp[0][0], node0, node1);
				__syncthreads();
				if (counter == FLUSHA-1) {
					int localIdx = min(FLUSHA2, counters[row]);
					int newCount = localIdx % FLUSHA;
					int nflush = localIdx - newCount;
					int cnt = min((int)atomicAdd(indexes + row * NX + col, nflush), (int)(maxOut - nflush));
					for (int i = 0; i < nflush; i += 1)
						buffer[((u64)(row * NX + col) * maxOut + cnt + i)] = tmp[row][i];
					for (int t = 0; t < newCount; t++) {
						tmp[row][t] = tmp[row][t + nflush];
					}
					counters[row] = newCount;
				}
				__syncthreads();
			}
			for (int row = lid; row < NX; row += dim) {
				int localIdx = min(FLUSHA2, counters[row]);
				int cnt = min((int)atomicAdd(indexes + row * NX + col, localIdx), (int)(maxOut - localIdx));
				for (int i = 0; i < localIdx; i += 1) {
					buffer[((u64)(row * NX + col) * maxOut + cnt + i)] = tmp[row][i];
				}
			}
			
		}

    template<int maxOut, typename EdgeOut>
        __global__ void SeedB(const siphash_keys &sipkeys, const EdgeOut * __restrict__ source, EdgeOut * __restrict__ destination, const u32 * __restrict__ sourceIndexes, u32 * __restrict__ destinationIndexes) {
            const int group = blockIdx.x;
            const int dim = blockDim.x;
            const int lid = threadIdx.x;
            const int FLUSHB2 = 2 * FLUSHB;

            __shared__ EdgeOut tmp[NX][FLUSHB2];
            __shared__ int counters[NX];

            // if (group>=0&&lid==0) printf("group  %d  -\n", group);
            for (int col = lid; col < NX; col += dim)
                counters[col] = 0;
            __syncthreads();
            const int row = group / NX;
            const int bucketEdges = min((int)sourceIndexes[group], (int)maxOut);
            const int loops = (bucketEdges + dim-1) / dim;
            for (int loop = 0; loop < loops; loop++) {
                int col; int counter = 0;
                const int edgeIndex = loop * dim + lid;
                if (edgeIndex < bucketEdges) {
                    const int index = group * maxOut + edgeIndex;
                    EdgeOut edge = __ldg(&source[index]);
                    if (null(edge)) continue;
                    u32 node1 = endpoint(sipkeys, edge, 0);
                    col = (node1 >> ZBITS) & XMASK;
                    counter = min((int)atomicAdd(counters + col, 1), (int)(FLUSHB2-1));
                    tmp[col][counter] = edge;
                }
                __syncthreads();
                if (counter == FLUSHB-1) {
                    int localIdx = min(FLUSHB2, counters[col]);
                    int newCount = localIdx % FLUSHB;
                    int nflush = localIdx - newCount;
                    int cnt = min((int)atomicAdd(destinationIndexes + row * NX + col, nflush), (int)(maxOut - nflush));
                    for (int i = 0; i < nflush; i += 1)
                        destination[((u64)(row * NX + col) * maxOut + cnt + i)] = tmp[col][i];
                    for (int t = 0; t < newCount; t++) {
                        tmp[col][t] = tmp[col][t + nflush];
                    }
                    counters[col] = newCount;
                }
                __syncthreads();
            }
            for (int col = lid; col < NX; col += dim) {
                int localIdx = min(FLUSHB2, counters[col]);
                int cnt = min((int)atomicAdd(destinationIndexes + row * NX + col, localIdx), (int)(maxOut - localIdx));
                for (int i = 0; i < localIdx; i += 1) {
                    destination[((u64)(row * NX + col) * maxOut + cnt + i)] = tmp[col][i];
                }
            }
        }


    template<int NP, int maxIn, typename EdgeIn, int maxOut, typename EdgeOut>
        __global__ void Round(const int round, const siphash_keys &sipkeys, const EdgeIn * __restrict__ src, EdgeOut * __restrict__ dst, const u32 * __restrict__ srcIds, u32 * __restrict__ dstIds) {
            const int group = blockIdx.x;
            const int dim = blockDim.x;
            const int lid = threadIdx.x;
            const static int COUNTERWORDS = NZ / 16; // 16 2-bit counters per 32-bit word

            __shared__ u32 ecounters[COUNTERWORDS];

            for (int i = lid; i < COUNTERWORDS; i += dim)
                ecounters[i] = 0;
            __syncthreads();


  for (int i = 0; i < NP; i++, src += NX2 * maxIn, srcIds += NX2) {
            const int edgesInBucket = min(srcIds[group], maxIn);
            const int loops = (edgesInBucket + dim-1) / dim;

            for (int loop = 0; loop < loops; loop++) {
                const int lindex = loop * dim + lid;
                if (lindex < edgesInBucket) {
                    const int index = maxIn * group + lindex;
                    EdgeIn edge = __ldg(&src[index]);
                    if (null(edge)) continue;
                    u32 node = endpoint(sipkeys, edge, round&1);
                    Increase2bCounter(ecounters, node & ZMASK);
                }
            }
  }
            __syncthreads();
  src -= NP * NX2 * maxIn; srcIds -= NP * NX2;
  for (int i = 0; i < NP; i++, src += NX2 * maxIn, srcIds += NX2) {
    const int edgesInBucket = min(srcIds[group], maxIn);
    const int loops = (edgesInBucket + dim-1) / dim;
            for (int loop = 0; loop < loops; loop++) {
                const int lindex = loop * dim + lid;
                if (lindex < edgesInBucket) {
                    const int index = maxIn * group + lindex;
                    EdgeIn edge = __ldg(&src[index]);
                    if (null(edge)) continue;
                    u32 node0 = endpoint(sipkeys, edge, round&1);
                    if (Read2bCounter(ecounters, node0 & ZMASK)) {
                        u32 node1 = endpoint(sipkeys, edge, (round&1)^1);
                        const int bucket = node1 >> ZBITS;
                        const int bktIdx = min(atomicAdd(dstIds + bucket, 1), maxOut - 1);
                        dst[bucket * maxOut + bktIdx] = (round&1) ? make_Edge(edge, *dst, node1, node0)
                            : make_Edge(edge, *dst, node0, node1);
                    }
                }
            }
  }
            // if (group==0&&lid==0) printf("round %d cnt(0,0) %d\n", round, sourceIndexes[0]);
        }

	template<int maxIn>
		__global__ void Tail(const uint2 *source, uint2 *destination, const u32 *sourceIndexes, u32 *destinationIndexes) {
	  const int lid = threadIdx.x;
	  const int group = blockIdx.x;
	  const int dim = blockDim.x;
	  int myEdges = sourceIndexes[group];
	  __shared__ int destIdx;

	  if (lid == 0)
		destIdx = atomicAdd(destinationIndexes, myEdges);

	  __syncthreads();
	  for (int i = lid; i < myEdges; i += dim)
		destination[destIdx + lid] = source[group * maxIn + lid];
	}


    __device__ u32 endpoint(const siphash_keys &sipkeys, u32 nonce, int uorv) {
        return dipnode(sipkeys, nonce, uorv);
    }

    __device__ u32 endpoint(const siphash_keys &sipkeys, uint2 nodes, int uorv) {
        return uorv ? nodes.y : nodes.x;
    }

    __device__ uint2 make_Edge(const u32 nonce, const uint2 dummy, const u32 node0, const u32 node1) {
        return make_uint2(node0, node1);
    }

    __device__ uint2 make_Edge(const uint2 edge, const uint2 dummy, const u32 node0, const u32 node1) {
        return edge;
    }

    __device__ u32 make_Edge(const u32 nonce, const u32 dummy, const u32 node0, const u32 node1) {
        return nonce;
    }

    edgetrimmer::edgetrimmer(const trimparams _tp, u32 _deviceId, int _selected) {
	selected = _selected;
        indexesSize = NX * NY * sizeof(u32);
        tp = _tp;
	
	cudaSetDevice(_deviceId);
        checkCudaErrors(cudaMalloc((void**)&dipkeys, sizeof(siphash_keys)));

		for(int i = 0; i < NB+1; i++){
			checkCudaErrors(cudaMalloc((void**)&indexesE[i], indexesSize));
		}
//        checkCudaErrors(cudaMalloc((void**)&indexesE2, indexesSize));

        sizeA = ROW_EDGES_A * NX * (selected == 0 && tp.expand > 0 ? sizeof(u32) : sizeof(uint2));
        sizeB = ROW_EDGES_B * NX * (selected == 0 && tp.expand > 1 ? sizeof(u32) : sizeof(uint2));

        const size_t bufferSize = sizeA + sizeB / NB;
        //fprintf(stderr, "bufferSize: %lu\n", bufferSize);
        checkCudaErrors(cudaMalloc((void**)&bufferA, bufferSize));
        bufferB  = bufferA + (bufferSize - sizeB);
        bufferAB = bufferA + sizeB / NB;
//		bufferB  = bufferA + sizeA / sizeof(ulonglong4);
//        bufferAB = bufferA + sizeB / sizeof(ulonglong4);
    }
    u64 edgetrimmer::globalbytes() const {
        return (sizeA+sizeB) + 2 * indexesSize + sizeof(siphash_keys);
    }
    edgetrimmer::~edgetrimmer() {
	cudaSetDevice(deviceId);
        cudaFree(bufferA);
		for(int i = 0; i < NB+1; i++){
			cudaFree(indexesE[i]);
		}
        cudaFree(dipkeys);
        cudaDeviceReset();
    }

int com(const void *a, const void *b){
	uint2 va = *(uint2*)a;
	uint2 vb = *(uint2*)b;
	if(va.x == vb.y) return va.y - vb.y;
	else return va.x - vb.x;
}

void saveFile(uint2*v, int n, char *filename){
	qsort(v, n, sizeof(uint2), com);
	FILE *fp = fopen(filename, "w");
	for(int i = 0; i < n; i++){
		fprintf(fp, "%d,%d\n", v[i].x, v[i].y);
	}
	fclose(fp);
}
    u32 edgetrimmer::trim(uint32_t device) {
        cudaSetDevice(device);

#ifdef TIMER
        cudaEvent_t start, stop;
        checkCudaErrors(cudaEventCreate(&start)); 
		checkCudaErrors(cudaEventCreate(&stop));
#endif

        cudaMemset(indexesE[1], 0, indexesSize);
        cudaMemcpy(dipkeys, &sipkeys, sizeof(sipkeys), cudaMemcpyHostToDevice);

        checkCudaErrors(cudaDeviceSynchronize());

#ifdef TIMER
        float durationA, durationB;
        cudaEventRecord(start, NULL);
#endif

	if(selected == 0){
		if(tp.expand == 0) Cuckoo_SeedA<EDGES_A, uint2><<<tp.genA.blocks, tp.genA.tpb>>>(*dipkeys, (uint2*)bufferAB, (int *)indexesE[1]);
		else Cuckoo_SeedA<EDGES_A, u32><<<tp.genA.blocks, tp.genA.tpb>>>(*dipkeys, (u32*)bufferAB, (int *)indexesE[1]);
	}
	else Cuckaroo_SeedA<EDGES_A><<<tp.genA.blocks, tp.genA.tpb>>>(*dipkeys, (uint2*)bufferAB, (int*)indexesE[1]);

        checkCudaErrors(cudaDeviceSynchronize()); 

#ifdef TIMER
        cudaEventRecord(stop, NULL);
        cudaEventSynchronize(stop); 
		cudaEventElapsedTime(&durationA, start, stop); 

		cudaEventRecord(start, NULL);
#endif
		
		cudaMemset(indexesE[0], 0, indexesSize);
//        const u32 halfA = sizeA/2 / sizeof(ulonglong4);
//        const u32 halfE = NX2 / 2;
		size_t qA = sizeA / NA;
		size_t qE = NX2 / NA;
		for(u32 i = 0; i < NA; i++){
			if(selected != 0 || tp.expand == 0){
				SeedB<EDGES_A, uint2><<<tp.genB.blocks/NA, tp.genB.tpb>>>(*dipkeys, (const uint2 *)(bufferAB + i*qA), (uint2*)(bufferA + i*qA), indexesE[1] + i*qE, indexesE[0] + i*qE);
//				SeedB<EDGES_A, uint2><<<tp.genB.blocks/2, tp.genB.tpb>>>(*dipkeys, (const uint2 *)(bufferAB + halfA), (uint2*)(bufferA+halfA), (const int *)(indexesE[1]+halfE), indexesE[0]+halfE);
			}else{
				SeedB<EDGES_A, u32><<<tp.genB.blocks/NA, tp.genB.tpb>>>(*dipkeys, (const u32 *)(bufferAB + i*qA), (u32*)(bufferA + i*qA), indexesE[1] + i*qE, indexesE[0] + i*qE);
//				SeedB<EDGES_A, u32><<<tp.genB.blocks/2, tp.genB.tpb>>>(*dipkeys, (const u32 *)(bufferAB+halfA), (u32*)(bufferA+halfA), (const int *)(indexesE[1]+halfE), indexesE[0]+halfE);	
			}
		}

#ifdef INDEX_DEBUG
		cudaMemcpy(hostA, indexesE[0], NX * NY * sizeof(u32), cudaMemcpyDeviceToHost);
		fprintf(stderr, "Index Number: %zu\n", hostA[0]);
#endif

#ifdef TIMER
		cudaEventRecord(stop, NULL);
        cudaEventSynchronize(stop); 
		cudaEventElapsedTime(&durationB, start, stop);
		fprintf(stderr, "Seeding completed in %.2f + %.2f ms\n", durationA, durationB);

		cudaEventRecord(start, NULL);
#endif

		for(u32 i = 0; i < NB; i++)
			cudaMemset(indexesE[1+i], 0, indexesSize);

		qA = sizeA/NB;
		const size_t qB = sizeB/NB;
		qE = NX2 / NB;
		for(u32 i = NB; i--; ){
			if(selected != 0 || tp.expand == 0)
				Round<1, EDGES_A, uint2, EDGES_B/NB, uint2><<<tp.trim.blocks/NB, tp.trim.tpb>>>(0, *dipkeys, (const uint2 *)(bufferA + i*qA), (uint2 *)(bufferB + i*qB), indexesE[0] + i*qE, indexesE[1 + i]); // to .632
			else if(tp.expand == 1)
				Round<1, EDGES_A, u32, EDGES_B/NB, uint2><<<tp.trim.blocks/NB, tp.trim.tpb>>>(0, *dipkeys, (const u32 *)(bufferA + i*qA), (uint2 *)(bufferB + i*qB), indexesE[0] + i*qE, indexesE[1 + i]); // to .632
			else 
				Round<1, EDGES_A, u32, EDGES_B/NB, u32><<<tp.trim.blocks/NB, tp.trim.tpb>>>(0, *dipkeys, (const u32 *)(bufferA + i*qA), (u32 *)(bufferB + i*qB), indexesE[0] + i*qE,indexesE[1+i]); // to .632
		}

		cudaMemset(indexesE[0], 0, indexesSize);

		if(selected != 0 || tp.expand < 2)
			Round<NB, EDGES_B/NB, uint2, EDGES_B/2, uint2><<<tp.trim.blocks, tp.trim.tpb>>>(1, *dipkeys, (const uint2 *)bufferB, (uint2 *)bufferA, indexesE[1], indexesE[0]); // to .296
		else 
			Round<NB, EDGES_B/NB, u32, EDGES_B/2, uint2><<<tp.trim.blocks, tp.trim.tpb>>>(1, *dipkeys, (const u32 *)bufferB, (uint2 *)bufferA, indexesE[1], indexesE[0]); // to .296

		cudaMemset(indexesE[1], 0, indexesSize);
		Round<1, EDGES_B/2, uint2, EDGES_A/4, uint2><<<tp.trim.blocks, tp.trim.tpb>>>(2, *dipkeys, (const uint2 *)bufferA, (uint2 *)bufferB, indexesE[0], indexesE[1]); // to .176
		cudaMemset(indexesE[0], 0, indexesSize);
		Round<1, EDGES_A/4, uint2, EDGES_B/4, uint2><<<tp.trim.blocks, tp.trim.tpb>>>(3, *dipkeys, (const uint2 *)bufferB, (uint2 *)bufferA, indexesE[1], indexesE[0]); // to .117 


#ifdef INDEX_DEBUG
		cudaMemcpy(nedges, indexesE[0], sizeof(u32), cudaMemcpyDeviceToHost);
		fprintf(stderr, "Index Number: %zu\n", nedges);
#endif

        cudaDeviceSynchronize();

        for (int round = 4; round < tp.ntrims; round += 2) {
			cudaMemset(indexesE[1], 0, indexesSize);
			Round<1, EDGES_B/4, uint2, EDGES_B/4, uint2><<<tp.trim.blocks, tp.trim.tpb>>>(round, *dipkeys,  (const uint2 *)bufferA, (uint2 *)bufferB, indexesE[0], indexesE[1]);
			cudaMemset(indexesE[0], 0, indexesSize);
			Round<1, EDGES_B/4, uint2, EDGES_B/4, uint2><<<tp.trim.blocks, tp.trim.tpb>>>(round+1, *dipkeys,  (const uint2 *)bufferB, (uint2 *)bufferA, indexesE[1], indexesE[0]);


#ifdef INDEX_DEBUG
			cudaMemcpy(&nedges, indexesE[0], sizeof(u32), cudaMemcpyDeviceToHost);
			fprintf(stderr, "Index Number: %zu\n", nedges);
#endif
        }

        checkCudaErrors(cudaDeviceSynchronize()); 

#ifdef TIMER
		cudaEventRecord(stop, NULL);
        cudaEventSynchronize(stop); 
		cudaEventElapsedTime(&durationA, start, stop);
		fprintf(stderr, "Round completed in %.2f ms\n", durationA);

		cudaEventRecord(start, NULL);
#endif

        cudaMemset(indexesE[1], 0, indexesSize);
        checkCudaErrors(cudaDeviceSynchronize()); 

        Tail<DUCK_B_EDGES/4><<<tp.tail.blocks, tp.tail.tpb>>>((const uint2 *)bufferA, (uint2 *)bufferB, indexesE[0], indexesE[1]);
        cudaMemcpy(&nedges, indexesE[1],sizeof(u32), cudaMemcpyDeviceToHost);


#ifdef TIMER
		cudaEventRecord(stop, NULL);
        checkCudaErrors(cudaEventSynchronize(stop)); 
		cudaEventElapsedTime(&durationA, start, stop);
		fprintf(stderr, "Tail completed in %.2f ms\n", durationA);

		checkCudaErrors(cudaEventDestroy(start));
		checkCudaErrors(cudaEventDestroy(stop));
#endif

        checkCudaErrors(cudaDeviceSynchronize());
//		fprintf(stderr, "Host A [0]: %zu\n", hostA[0]);
/*	uint2 *tmpa = (uint2*)malloc(sizeof(uint2) * hostA[0]);
	cudaMemcpy(tmpa, bufferB, sizeof(uint2)*hostA[0], cudaMemcpyDeviceToHost);
	saveFile(tmpa, hostA[0], "result.txt");
	free(tmpa);*/
        return nedges;
    }


};
