/*	
 * noise_remover_v3.cu
 *
 * This program removes noise from an image based on Speckle Reducing Anisotropic Diffusion
 * Y. Yu, S. Acton, Speckle reducing anisotropic diffusion, 
 * IEEE Transactions on Image Processing 11(11)(2002) 1260-1270 <http://people.virginia.edu/~sc5nf/01097762.pdf>
 * Original implementation is Modified by Burak BASTEM
 */

#include <cuda_runtime.h>

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
__global__ void compute_1(int height, int width, long k, unsigned char *image_device, float *north_deriv_device, 
	float *south_deriv_device, float *west_deriv_device, float *east_deriv_device, float gradient_square,
	float laplacian, float num, float den, float std_dev, float std_dev2, float *diff_coef_device)
{
	int i = blockIdx.x * blockDim.x + threadIdx.x;
	int j = blockIdx.y * blockDim.y + threadIdx.y;
		float east_deriv_local =0.0;
		float diff_coef_local = 0.0;
		float north_deriv_local = 0.0;
		float west_deriv_local = 0.0;
		float south_deriv_local = 0.0;

	if(i > 0 && i < height-1 && j > 0 && j < width-1) {
		k = i * width + j;	// position of current element
		unsigned char image_local = image_device[k];

		north_deriv_device[k] = image_device[(i - 1) * width + j] - image_local;	// north derivative --- 1 floating point arithmetic operations
		south_deriv_device[k] = image_device[(i + 1) * width + j] - image_local;	// south derivative --- 1 floating point arithmetic operations
		west_deriv_device[k] = image_device[i * width + (j - 1)] - image_local;	// west derivative --- 1 floating point arithmetic operations
		 east_deriv_device[k] = image_device[i * width + (j + 1)] - image_local;	// east derivative --- 1 floating point arithmetic operations
		
		
		 east_deriv_local = east_deriv_device[k];
		 diff_coef_local = diff_coef_device[k];
		 north_deriv_local = north_deriv_device[k];
		 west_deriv_local = west_deriv_device[k];
		 south_deriv_local = south_deriv_device[k];



		gradient_square = (north_deriv_local * north_deriv_local + south_deriv_local * south_deriv_local + west_deriv_local * west_deriv_local + east_deriv_local * east_deriv_local) / (image_local * image_local); // 9 floating point arithmetic operations
		laplacian = (north_deriv_local + south_deriv_local + west_deriv_local + east_deriv_local) / image_local; // 4 floating point arithmetic operations
		num = (0.5 * gradient_square) - ((1.0 / 16.0) * (laplacian * laplacian)); // 5 floating point arithmetic operations
		den = 1 + (.25 * laplacian); // 2 floating point arithmetic operations
		std_dev2 = num / (den * den); // 2 floating point arithmetic operations
		den = (std_dev2 - std_dev) / (std_dev * (1 + std_dev)); // 4 floating point arithmetic operations
		diff_coef_local = 1.0 / (1.0 + den); // 2 floating point arithmetic operations
		if (diff_coef_local < 0) {
			diff_coef_device[k] = 0;
		} else if (diff_coef_local > 1)	{
			diff_coef_device[k] = 1;
		}
	} else {
		return;
	}

}


// COMPUTE 2
// divergence and image update --- 10 floating point arithmetic operations per element -> 10*(height-1)*(width-1) in total
__global__ void compute_2(int height, int width, long k, unsigned char *image_device, float lambda, float diff_coef_north, 
						float diff_coef_south, float diff_coef_west, float diff_coef_east, float divergence, float *diff_coef_device,
						float *north_deriv_device, float *south_deriv_device, float *west_deriv_device, float *east_deriv_device)
{

	__shared__ unsigned char imageShared[SQRT_BLOCK_SIZE][SQRT_BLOCK_SIZE];

	int i = blockIdx.x * blockDim.x + threadIdx.x;
	int j = blockIdx.y * blockDim.y + threadIdx.y;

	if(i > 0 && i < height-1 && j > 0 && j < width-1) {
		k = i * width + j;	// get position of current element

		imageShared[threadIdx.x][threadIdx.y] = image_device[k];
		//__syncthreads();

		diff_coef_north = diff_coef_device[k];	// north diffusion coefficient
		diff_coef_south = diff_coef_device[(i + 1) * width + j];	// south diffusion coefficient
		diff_coef_west = diff_coef_device[k];	// west diffusion coefficient
		diff_coef_east = diff_coef_device[i * width + (j + 1)];	// east diffusion coefficient				
		divergence = diff_coef_north * north_deriv_device[k] + diff_coef_south * south_deriv_device[k] + diff_coef_west * west_deriv_device[k] + diff_coef_east * east_deriv_device[k]; // --- 7 floating point arithmetic operations
		image_device[k] = imageShared[threadIdx.x][threadIdx.y] + 0.25 * lambda * divergence; // --- 3 floating point arithmetic operations
	
		// __syncthreads();
		// image_device[k] = imageShared[threadIdx.x][threadIdx.y]:

	} else {
		return;
	}
}	

// REDUCTION
__global__ void reduction(unsigned char *image_device, float *sum_device, float *sum2_device, int len)
{
	unsigned int init = 2 * blockIdx.x * blockDim.x;
	__shared__ float shared_sum[2 * SQRT_BLOCK_SIZE]; //do reduction in shared mem
	__shared__ float shared_sum2[2 * SQRT_BLOCK_SIZE]; //do reduction in shared mem
			if((init + threadIdx.x) <= len) 
	{
		shared_sum[threadIdx.x] = image_device[init + threadIdx.x];
		shared_sum2[threadIdx.x] = image_device[init + threadIdx.x];
	} else {
		shared_sum[threadIdx.x] = 0.0;
		shared_sum2[threadIdx.x] = 0.0;
	}

			if((init + blockDim.x + threadIdx.x) <= len)
	{
		shared_sum[blockDim.x + threadIdx.x] = image_device[init + blockDim.x + threadIdx.x]; 
		shared_sum2[blockDim.x + threadIdx.x] = image_device[init + blockDim.x + threadIdx.x];
	} else {
		shared_sum[blockDim.x + threadIdx.x] = 0.0;
		shared_sum2[blockDim.x + threadIdx.x] =0.0;
	}



	 for(unsigned int i = 1; i < blockDim.x; i *= 2)
        {
                __syncthreads();
                int index = 2*i* threadIdx.x;
                if(index < blockDim.x)
                {
                        shared_sum[index] += shared_sum[index + i];
                        shared_sum2[index] += shared_sum2[index + i]*shared_sum2[index + i];
                }

                __syncthreads();

                if(threadIdx.x == 0 && ((blockDim.x * blockIdx.x + threadIdx.x) * 2) <= len){
                        sum_device[blockIdx.x] = shared_sum[threadIdx.x];
                        sum2_device[blockIdx.x] = shared_sum2[threadIdx.x]*shared_sum2[threadIdx.x];
                }
        }


}

int main(int argc, char *argv[]) {
	
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
	unsigned char *image_device;

	//device variables
	float *north_deriv_device, *south_deriv_device, *west_deriv_device, *east_deriv_device;
	float *sum_device, *sum2_device;
	float *diff_coef_device;

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
	cudaMalloc((void**)&north_deriv_device, sizeof(float)*n_pixels);
	cudaMemcpy((void**)north_deriv_device, north_deriv, sizeof(float)*n_pixels, cudaMemcpyHostToDevice);
	
	south_deriv = (float*) malloc(sizeof(float) * n_pixels);	// south derivative
	cudaMalloc((void**)&south_deriv_device, sizeof(float)*n_pixels);
	cudaMemcpy((void**)south_deriv_device, south_deriv, sizeof(float)*n_pixels, cudaMemcpyHostToDevice);
	
	west_deriv = (float*) malloc(sizeof(float) * n_pixels);	// west derivative
	cudaMalloc((void**)&west_deriv_device, sizeof(float)*n_pixels);
	cudaMemcpy((void**)west_deriv_device, west_deriv, sizeof(float)*n_pixels, cudaMemcpyHostToDevice);
	
	east_deriv = (float*) malloc(sizeof(float) * n_pixels);	// east derivative
	cudaMalloc((void**)&east_deriv_device, sizeof(float)*n_pixels);
	cudaMemcpy((void**)east_deriv_device, east_deriv, sizeof(float)*n_pixels, cudaMemcpyHostToDevice);
	
	diff_coef  = (float*) malloc(sizeof(float) * n_pixels);	// diffusion coefficient
	cudaMalloc((void**)&diff_coef_device, sizeof(float)*n_pixels);
	cudaMemcpy((void**)diff_coef_device, diff_coef, sizeof(float)*n_pixels, cudaMemcpyHostToDevice);

	cudaMalloc((void**)&sum_device, sizeof(float));
	cudaMemcpy((void**)sum_device, &sum, sizeof(float), cudaMemcpyHostToDevice);

	cudaMalloc((void**)&sum2_device, sizeof(float));
	cudaMemcpy((void**)sum2_device, &sum2, sizeof(float), cudaMemcpyHostToDevice);

	cudaMalloc((void**)&image_device, (sizeof(unsigned char)*n_pixels) * pixelWidth);
	cudaMemcpy((void**)image_device, image, (sizeof(unsigned char)*n_pixels) * pixelWidth, cudaMemcpyHostToDevice);


	time_4 = get_time();

	// setup execution configurations, creating 2D threads 
	dim3 threads(SQRT_BLOCK_SIZE, SQRT_BLOCK_SIZE, 1);
	dim3 grid(height/threads.x, width/threads.y);

	// Part V: compute --- n_iter * (3 * height * width + 42 * (height-1) * (width-1) + 6) floating point arithmetic operations in totaL
	for (int iter = 0; iter < n_iter; iter++) 
	{
		sum = 0;
		sum2 = 0;

		// REDUCTION
		reduction<<<grid, threads>>>(image_device, sum_device, sum2_device, height*width*pixelWidth);
		cudaDeviceSynchronize();

		// Get results back to host
		cudaMemcpy(&sum,sum_device,sizeof(float), cudaMemcpyDeviceToHost);
		cudaMemcpy(&sum2,sum2_device,sizeof(float), cudaMemcpyDeviceToHost);

		// STATISTICS
		mean = sum / n_pixels; // --- 1 floating point arithmetic operations
		variance = (sum2 / n_pixels) - mean * mean; // --- 3 floating point arithmetic operations
		std_dev = variance / (mean * mean); // --- 2 floating point arithmetic operations

		// COMPUTE 1
		compute_1<<<grid,threads>>>(height, width, k, image_device, north_deriv_device, south_deriv_device, west_deriv_device, east_deriv_device, gradient_square, laplacian, num, den, std_dev, std_dev2, diff_coef_device);
		cudaDeviceSynchronize();

		// COMPUTE 2 

		compute_2<<<grid,threads>>>(height, width, k, image_device, lambda, diff_coef_north, diff_coef_south, diff_coef_west, diff_coef_east, divergence, diff_coef_device, north_deriv_device, south_deriv_device, west_deriv_device, east_deriv_device);

		// Get Output Image back to the host
		cudaMemcpy(image,image_device,sizeof(unsigned char)*n_pixels * pixelWidth, cudaMemcpyDeviceToHost);
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
	cudaFree(image_device);

	free(north_deriv);
	cudaFree(north_deriv_device);

	free(south_deriv);
	cudaFree(south_deriv_device);

	free(west_deriv);
	cudaFree(west_deriv_device);

	free(east_deriv);
	cudaFree(east_deriv_device);

	free(diff_coef);
	cudaFree(diff_coef_device);

	cudaFree(sum_device);
	cudaFree(sum2_device);
	
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
	printf("V3 blocksize: %d\n", SQRT_BLOCK_SIZE*SQRT_BLOCK_SIZE);
	return 0;
}