CC = g++
CFLAGS  = -std=c++0x -g -Wall -O3

all: noise_remover noise_remover_v1 noise_remover_v2 noise_remover_v3

noise_remover: noise_remover.o
	$(CC) $(CFLAGS) noise_remover.o -lm -o noise_remover
	
noise_remover.o: noise_remover.cpp
	$(CC) $(CFLAGS) -c  noise_remover.cpp

noise_remover_v1:
	nvcc noise_remover_v1.cu -o  noise_remover_v1

noise_remover_v2:
	nvcc noise_remover_v2.cu -o  noise_remover_v2

noise_remover_v3:
	nvcc noise_remover_v3.cu -o  noise_remover_v3

clean:
	rm -rf *.o noise_remover noise_remover_v1 noise_remover_v2 noise_remover_v3
