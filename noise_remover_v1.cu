/*	
 * noise_remover_v1.cu
 *
 * This program removes noise from an image based on Speckle Reducing Anisotropic Diffusion
 * Y. Yu, S. Acton, Speckle reducing anisotropic diffusion, 
 * IEEE Transactions on Image Processing 11(11)(2002) 1260-1270 <http://people.virginia.edu/~sc5nf/01097762.pdf>
 * Original implementation is Modified by Burak BASTEM
 */

#include <cuda_runtime.h>
#include <cuda.h>

#include <stdlib.h>
#include <stdio.h>
#include <math.h>
#include <string.h>
#include <sys/time.h>
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#define MATCH(s) (!strcmp(argv[ac], (s)))

#define SQRT_BLOCK_SIZE 4

static const double kMicro = 1.0e-6;

double get_time() {
	struct timeval TV;
	struct timezone TZ;
	const int RC = gettimeofday(&TV, &TZ);
	if(RC == -1) {
		printf("ERROR: Bad call to gettimeofday\n");
		return(-1);
	}
	return( ((double)TV.tv_sec) + kMicro * ((double)TV.tv_usec) );
}


//COMPUTE 1
// --- 32 floating point arithmetic operations per element -> 32*(height-1)*(width-1) in total
__global__ void compute_1(int height, int width, long k, unsigned char *image_d, float *north_deriv_d, 
						float *south_deriv_d, float *west_deriv_d, float *east_deriv_d, float gradient_square,
						float laplacian, float num, float den, float std_dev, float std_dev2, float *diff_coef_d)
{
	int i = blockIdx.x * blockDim.x + threadIdx.x;
	int j = blockIdx.y * blockDim.y + threadIdx.y;

	if(i > 0 && i < height-1 && j > 0 && j < width-1) {
		k = i * width + j;	// position of current element
		north_deriv_d[k] = image_d[(i - 1) * width + j] - image_d[k];	// north derivative --- 1 floating point arithmetic operations
		south_deriv_d[k] = image_d[(i + 1) * width + j] - image_d[k];	// south derivative --- 1 floating point arithmetic operations
		west_deriv_d[k] = image_d[i * width + (j - 1)] - image_d[k];	// west derivative --- 1 floating point arithmetic operations
		east_deriv_d[k] = image_d[i * width + (j + 1)] - image_d[k];	// east derivative --- 1 floating point arithmetic operations
		gradient_square = (north_deriv_d[k] * north_deriv_d[k] + south_deriv_d[k] * south_deriv_d[k] + west_deriv_d[k] * west_deriv_d[k] + east_deriv_d[k] * east_deriv_d[k]) / (image_d[k] * image_d[k]); // 9 floating point arithmetic operations
		laplacian = (north_deriv_d[k] + south_deriv_d[k] + west_deriv_d[k] + east_deriv_d[k]) / image_d[k]; // 4 floating point arithmetic operations
		num = (0.5 * gradient_square) - ((1.0 / 16.0) * (laplacian * laplacian)); // 5 floating point arithmetic operations
		den = 1 + (.25 * laplacian); // 2 floating point arithmetic operations
		std_dev2 = num / (den * den); // 2 floating point arithmetic operations
		den = (std_dev2 - std_dev) / (std_dev * (1 + std_dev)); // 4 floating point arithmetic operations
		diff_coef_d[k] = 1.0 / (1.0 + den); // 2 floating point arithmetic operations
		if (diff_coef_d[k] < 0) {
			diff_coef_d[k] = 0;
		} else if (diff_coef_d[k] > 1)	{
			diff_coef_d[k] = 1;
		}
	} else {
		return;
	}
}

// COMPUTE 2
// divergence and image update --- 10 floating point arithmetic operations per element -> 10*(height-1)*(width-1) in total
__global__ void compute_2(int height, int width, long k, unsigned char *image_d, float lambda, float diff_coef_north, 
						float diff_coef_south, float diff_coef_west, float diff_coef_east, float divergence, float *diff_coef_d,
						float *north_deriv_d, float *south_deriv_d, float *west_deriv_d, float *east_deriv_d)
{
	int i = blockIdx.x * blockDim.x + threadIdx.x;
	int j = blockIdx.y * blockDim.y + threadIdx.y;

	if(i > 0 && i < height-1 && j > 0 && j < width-1) {
		k = i * width + j;	// get position of current element
		diff_coef_north = diff_coef_d[k];	// north diffusion coefficient
		diff_coef_south = diff_coef_d[(i + 1) * width + j];	// south diffusion coefficient
		diff_coef_west = diff_coef_d[k];	// west diffusion coefficient
		diff_coef_east = diff_coef_d[i * width + (j + 1)];	// east diffusion coefficient				
		divergence = diff_coef_north * north_deriv_d[k] + diff_coef_south * south_deriv_d[k] + diff_coef_west * west_deriv_d[k] + diff_coef_east * east_deriv_d[k]; // --- 7 floating point arithmetic operations
		image_d[k] = image_d[k] + 0.25 * lambda * divergence; // --- 3 floating point arithmetic operations
	} else {
		return;
	}
}	

// REDUCTION
// __global__ void reduction(unsigned char *image_d, float *sum_d, float *sum2_d, int height, int width, int pixelWidth)
// {
// 	__shared__ float seg_sum[2 * SQRT_BLOCK_SIZE];
// 	int globalThreadId = blockDim.x * blockIdx.x + threadIdx.x;
// 	unsigned int threadId = threadIdx.x;
// 	unsigned int start = 2 * blockIdx.x * blockDim.x;

// 	int length = height * width * pixelWidth;

// 	if((start + threadId) <= length) 
// 	{
// 		seg_sum[threadId] = image_d[start + threadId];
// 	} else {
// 		seg_sum[threadId] = 0.0;
// 	}

// 	if((start + blockDim.x + threadId) <= length)
// 	{
// 		seg_sum[blockDim.x + threadId] = image_d[start + blockDim.x + threadId]; 
// 	} else {
// 		seg_sum[blockDim.x + threadId] = 0.0;
// 	}

// 	for(unsigned int stage = blockDim.x; stage > 0; stage /= 2) 
// 	{
// 		__syncthreads();

// 		if(threadId < stage)
// 		{
// 			seg_sum[threadId] += seg_sum[threadId + stage];
// 		}

// 		__syncthreads();

// 		if(threadId == 0 && (globalThreadId * 2) <= length){
// 			sum_d[blockIdx.x] = seg_sum[threadId];
//   			sum2_d[blockIdx.x] = seg_sum[threadId]*seg_sum[threadId];
// 		}
// 	}

// }

__device__ void warpReduce(int *sdata, unsigned int tid)
{
    if (SQRT_BLOCK_SIZE >= 64) sdata[tid] += sdata[tid + 32];
    if (SQRT_BLOCK_SIZE >= 32) sdata[tid] += sdata[tid + 16];
    if (SQRT_BLOCK_SIZE >= 16) sdata[tid] += sdata[tid +  8];
    if (SQRT_BLOCK_SIZE >=  8) sdata[tid] += sdata[tid +  4];
    if (SQRT_BLOCK_SIZE >=  4) sdata[tid] += sdata[tid +  2];
    if (SQRT_BLOCK_SIZE >=  2) sdata[tid] += sdata[tid +  1];
}

__global__ void reduceCUDA(unsigned char *g_idata, float *g_odata,float *g_odata2,int n)
{
    __shared__ int sdata[SQRT_BLOCK_SIZE];
	__shared__ int sdata2[SQRT_BLOCK_SIZE];

    unsigned int tid = threadIdx.x;
    //size_t i = blockIdx.x*(SQRT_BLOCK_SIZE*2) + tid;
    //size_t gridSize = blockSize*2*gridDim.x;
    unsigned int i = blockIdx.x*(SQRT_BLOCK_SIZE) + tid;
    unsigned int gridSize = SQRT_BLOCK_SIZE*gridDim.x;
    sdata[tid] = 0;
	sdata2[tid] = 0;

    while (i < n) { 
					sdata[tid] += g_idata[i]; 
					sdata2[tid] += sdata[tid]*sdata[tid];
					i += gridSize;
					 
	
	}
    __syncthreads();

    if (SQRT_BLOCK_SIZE >= 1024) {
		if (tid < 512) {
			sdata[tid] += sdata[tid + 512]; 
			sdata2[tid] = sdata[tid]*sdata[tid];
		}
		__syncthreads(); 
	}
	if (SQRT_BLOCK_SIZE >= 512) {
		if (tid < 256) {
			sdata[tid] += sdata[tid + 256]; 
			sdata2[tid] = sdata[tid]*sdata[tid];
		}
		__syncthreads(); 
	}
	if (SQRT_BLOCK_SIZE >= 256) {
		if (tid < 128) {
			sdata[tid] += sdata[tid + 128]; 
			sdata2[tid] = sdata[tid]*sdata[tid];
		}
		__syncthreads(); 
	}
	if (SQRT_BLOCK_SIZE >= 128) {
		if (tid < 64) {
			sdata[tid] += sdata[tid + 64]; 
			sdata2[tid] = sdata[tid]*sdata[tid];
		}
		__syncthreads(); 
	}


    if (tid < 32) warpReduce<SQRT_BLOCK_SIZE>(sdata, tid);
    if (tid == 0){
	g_odata[blockIdx.x] = sdata[0];
	g_odata2[blockIdx.x] = sdata2[0];
	}
}

int main(int argc, char *argv[]) 
{	
	// Part I: allocate and initialize variables
	double time_0, time_1, time_2, time_3, time_4, time_5, time_6, time_7, time_8;	// time variables
	
	time_0 = get_time();
	
	const char *filename = "input.pgm";
	const char *outputname = "output.png";	
	int width, height, pixelWidth, n_pixels;
	int n_iter = 50;
	float lambda = 0.5;
	float mean, variance, std_dev;	//local region statistics
	float *north_deriv, *south_deriv, *west_deriv, *east_deriv;	// directional derivatives
	float sum, sum2;	// calculation variables
	float gradient_square, laplacian, num, den, std_dev2, divergence;	// calculation variables
	float *diff_coef;	// diffusion coefficient
	float diff_coef_north, diff_coef_south, diff_coef_west, diff_coef_east;	// directional diffusion coefficients
	long k;	// current pixel index
	unsigned char *image_d;

	//device variables
	float *north_deriv_d, *south_deriv_d, *west_deriv_d, *east_deriv_d;
	float *sum_d, *sum2_d;
	float *diff_coef_d;

	time_1 = get_time();	

	// Part II: parse command line arguments
	if(argc<2) {
	  printf("Usage: %s [-i < filename>] [-iter <n_iter>] [-l <lambda>] [-o <outputfilename>]\n",argv[0]);
	  return(-1);
	}
	for(int ac=1;ac<argc;ac++) {
		if(MATCH("-i")) {
			filename = argv[++ac];
		} else if(MATCH("-iter")) {
			n_iter = atoi(argv[++ac]);
		} else if(MATCH("-l")) {
			lambda = atof(argv[++ac]);
		} else if(MATCH("-o")) {
			outputname = argv[++ac];
		//} else if(MATCH("-b")) {
			//SQRT_BLOCK_SIZE = atoi(argv[++ac]);
		} else {
		printf("Usage: %s [-i < filename>] [-iter <n_iter>] [-l <lambda>] [-o <outputfilename>]\n",argv[0]);
		return(-1);
		}
	}

	time_2 = get_time();


	// Part III: read image	
	printf("Reading image...\n");
	unsigned char *image = stbi_load(filename, &width, &height, &pixelWidth, 0);
	if (!image) {
		fprintf(stderr, "Couldn't load image.\n");
		return (-1);
	}
	printf("Image Read. Width : %d, Height : %d, nComp: %d\n",width,height,pixelWidth);
	n_pixels = height * width;
	
	time_3 = get_time();


	// Part IV: allocate variables
	north_deriv = (float*) malloc(sizeof(float) * n_pixels);	// north derivative
	cudaMalloc((void**)&north_deriv_d, sizeof(float)*n_pixels);
	cudaMemcpy((void**)north_deriv_d, north_deriv, sizeof(float)*n_pixels, cudaMemcpyHostToDevice);
	
	south_deriv = (float*) malloc(sizeof(float) * n_pixels);	// south derivative
	cudaMalloc((void**)&south_deriv_d, sizeof(float)*n_pixels);
	cudaMemcpy((void**)south_deriv_d, south_deriv, sizeof(float)*n_pixels, cudaMemcpyHostToDevice);
	
	west_deriv = (float*) malloc(sizeof(float) * n_pixels);	// west derivative
	cudaMalloc((void**)&west_deriv_d, sizeof(float)*n_pixels);
	cudaMemcpy((void**)west_deriv_d, west_deriv, sizeof(float)*n_pixels, cudaMemcpyHostToDevice);
	
	east_deriv = (float*) malloc(sizeof(float) * n_pixels);	// east derivative
	cudaMalloc((void**)&east_deriv_d, sizeof(float)*n_pixels);
	cudaMemcpy((void**)east_deriv_d, east_deriv, sizeof(float)*n_pixels, cudaMemcpyHostToDevice);
	
	diff_coef  = (float*) malloc(sizeof(float) * n_pixels);	// diffusion coefficient
	cudaMalloc((void**)&diff_coef_d, sizeof(float)*n_pixels);
	cudaMemcpy((void**)diff_coef_d, diff_coef, sizeof(float)*n_pixels, cudaMemcpyHostToDevice);

	cudaMalloc((void**)&sum_d, sizeof(float));
	cudaMemcpy((void**)sum_d, &sum, sizeof(float), cudaMemcpyHostToDevice);

	 cudaMalloc((void**)&sum2_d, sizeof(float));
	 cudaMemcpy((void**)sum2_d, &sum2, sizeof(float), cudaMemcpyHostToDevice);

	cudaMalloc((void**)&image_d, (sizeof(unsigned char)*n_pixels) * pixelWidth);
	cudaMemcpy((void**)image_d, image, (sizeof(unsigned char)*n_pixels) * pixelWidth, cudaMemcpyHostToDevice);


	time_4 = get_time();

	// setup execution configurations, creating 2D threads 
	dim3 threads(SQRT_BLOCK_SIZE, SQRT_BLOCK_SIZE, 1);
	dim3 grid(height/threads.x, width/threads.y);

	// Part V: compute --- n_iter * (3 * height * width + 42 * (height-1) * (width-1) + 6) floating point arithmetic operations in totaL
	for (int iter = 0; iter < n_iter; iter++) {
		sum = 0;
		sum2 = 0;

		// REDUCTION
		reduceCUDA<<<grid,threads>>>(image_d, sum_d, sum2_d,height * width * pixelWidth);
		//reduction<<<grid, threads>>>(image_d, sum);
		cudaDeviceSynchronize();

		// Get results back to host
		//cudaMemcpy(&sum,sum_d,sizeof(float), cudaMemcpyDeviceToHost);
		cudaMemcpy(&sum,sum_d,sizeof(float), cudaMemcpyDeviceToHost);
		cudaMemcpy(&sum2,sum2_d,sizeof(float), cudaMemcpyDeviceToHost);
		//sum2 = sum*sum;
		//cudaMemcpy(&sum2,sum2_d,sizeof(float), cudaMemcpyDeviceToHost);

		// STATISTICS
		mean = sum / n_pixels; // --- 1 floating point arithmetic operations
		variance = (sum2 / n_pixels) - mean * mean; // --- 3 floating point arithmetic operations
		std_dev = variance / (mean * mean); // --- 2 floating point arithmetic operations
	
		// COMPUTE 1
	    compute_1<<<grid,threads>>>(height, width, k, image_d, north_deriv_d, south_deriv_d, west_deriv_d, east_deriv_d, gradient_square, laplacian, num, den, std_dev, std_dev2, diff_coef_d);
	    cudaDeviceSynchronize();

		// COMPUTE 2 
		compute_2<<<grid,threads>>>(height, width, k, image_d, lambda, diff_coef_north, diff_coef_south, diff_coef_west, diff_coef_east, divergence, diff_coef_d, north_deriv_d, south_deriv_d, west_deriv_d, east_deriv_d);

		// Get Output Image back to the host
		cudaMemcpy(image,image_d,sizeof(unsigned char)*n_pixels * pixelWidth, cudaMemcpyDeviceToHost);
	}

	time_5 = get_time();


	// Part VI: write image to file
	stbi_write_png(outputname, width, height, pixelWidth, image, 0);
	time_6 = get_time();

	
	// Part VII: get average of sum of pixels for testing and calculate GFLOPS
	// FOR VALIDATION - DO NOT PARALLELIZE
	float test = 0;
	for (int i = 0; i < height; i++) {
			for (int j = 0; j < width; j++) {
				test += image[i * width + j];
		}
	}

	test /= n_pixels;	

	float gflops = (float) (n_iter * 1E-9 * (3 * height * width + 42 * (height-1) * (width-1) + 6)) / (time_5 - time_4);
	
	time_7 = get_time();


	// Part VII: deallocate variables
	stbi_image_free(image);
	cudaFree(image_d);

	free(north_deriv);
	cudaFree(north_deriv_d);

	free(south_deriv);
	cudaFree(south_deriv_d);

	free(west_deriv);
	cudaFree(west_deriv_d);

	free(east_deriv);
	cudaFree(east_deriv_d);

	free(diff_coef);
	cudaFree(diff_coef_d);

	cudaFree(sum_d);
	cudaFree(sum2_d);

	time_8 = get_time();

	// print
	printf("Time spent in different stages of the application:\n");
	printf("%9.6f s => Part I: allocate and initialize variables\n", (time_1 - time_0));
	printf("%9.6f s => Part II: parse command line arguments\n", (time_2 - time_1));
	printf("%9.6f s => Part III: read image\n", (time_3 - time_2));
	printf("%9.6f s => Part IV: allocate variables\n", (time_4 - time_3));
	printf("%9.6f s => Part V: compute\n", (time_5 - time_4));
	printf("%9.6f s => Part VI: write image to file\n", (time_6 - time_5));
	printf("%9.6f s => Part VII: get average of sum of pixels for testing and calculate GFLOPS\n", (time_7 - time_6));
	printf("%9.6f s => Part VIII: deallocate variables\n", (time_7 - time_6));
	printf("Total time: %9.6f s\n", (time_8 - time_0));
	printf("Average of sum of pixels: %9.6f\n", test);
	printf("GFLOPS: %f\n", gflops);
	printf("V1 blocksize: %d\n", SQRT_BLOCK_SIZE*SQRT_BLOCK_SIZE);
	return 0;
}