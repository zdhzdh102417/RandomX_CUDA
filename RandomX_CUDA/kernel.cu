/*
Copyright (c) 2019 SChernykh

This file is part of RandomX CUDA.

RandomX CUDA is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

RandomX is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with RandomX.  If not, see<http://www.gnu.org/licenses/>.
*/

#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include <stdint.h>
#include <stdio.h>
#include <chrono>
#include <vector>
#include "blake2/blake2.h"
#include "aes/hashAes1Rx4.hpp"

#include "blake2b_cuda.hpp"
#include "aes_cuda.hpp"
#include "randomx_cuda.hpp"

bool test_mining();
void tests();

int main(int argc, char** argv)
{
	if (argc < 3)
	{
		printf("Usage: RandomX_CUDA.exe --[mine|test] device_id\n");
		printf("Examples:\nRandomX_CUDA.exe --test 0\nRandomX_CUDA.exe --mine 0\n");
		return 0;
	}

	const int device_id = atoi(argv[2]);

	cudaError_t cudaStatus = cudaSetDevice(device_id);
	if (cudaStatus != cudaSuccess)
	{
		fprintf(stderr, "cudaSetDevice failed! Do you have a CUDA-capable GPU installed?");
		return 1;
	}

	// Lowers CPU usage to almost 0, but reduces test results
	//uint32_t flags;
	//if (cudaGetDeviceFlags(&flags) == cudaSuccess)
	//	cudaSetDeviceFlags(flags | cudaDeviceScheduleBlockingSync);

	if (strcmp(argv[1], "--mine") == 0)
		test_mining();
	else if (strcmp(argv[1], "--test") == 0)
		tests();

	cudaStatus = cudaDeviceReset();
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaDeviceReset failed!");
		return 1;
	}

	return 0;
}

using namespace std::chrono;

static uint8_t blockTemplate[] = {
		0x07, 0x07, 0xf7, 0xa4, 0xf0, 0xd6, 0x05, 0xb3, 0x03, 0x26, 0x08, 0x16, 0xba, 0x3f, 0x10, 0x90, 0x2e, 0x1a, 0x14,
		0x5a, 0xc5, 0xfa, 0xd3, 0xaa, 0x3a, 0xf6, 0xea, 0x44, 0xc1, 0x18, 0x69, 0xdc, 0x4f, 0x85, 0x3f, 0x00, 0x2b, 0x2e,
		0xea, 0x00, 0x00, 0x00, 0x00, 0x77, 0xb2, 0x06, 0xa0, 0x2c, 0xa5, 0xb1, 0xd4, 0xce, 0x6b, 0xbf, 0xdf, 0x0a, 0xca,
		0xc3, 0x8b, 0xde, 0xd3, 0x4d, 0x2d, 0xcd, 0xee, 0xf9, 0x5c, 0xd2, 0x0c, 0xef, 0xc1, 0x2f, 0x61, 0xd5, 0x61, 0x09
};

struct GPUPtr
{
	explicit GPUPtr(size_t size)
	{
		if (cudaMalloc((void**) &p, size) != cudaSuccess)
			p = nullptr;
	}

	~GPUPtr()
	{
		if (p)
			cudaFree(p);
	}

	operator void*() const { return p; }

private:
	void* p;
};

bool test_mining()
{
	cudaError_t cudaStatus;

	size_t free_mem, total_mem;
	{
		GPUPtr tmp(256);
		cudaStatus = cudaMemGetInfo(&free_mem, &total_mem);
		if (cudaStatus != cudaSuccess)
		{
			fprintf(stderr, "Failed to get free memory info!");
			return false;
		}
	}

	printf("%zu MB GPU memory free\n", free_mem >> 20);
	printf("%zu MB GPU memory total\n", total_mem >> 20);

	// There should be enough GPU memory for the 2 GB dataset, 32 scratchpads and 64 MB for everything else
	if (free_mem <= DATASET_SIZE + (32U * SCRATCHPAD_SIZE) + (64U << 20))
	{
		fprintf(stderr, "Not enough free GPU memory!", free_mem >> 20);
		return false;
	}

	const size_t batch_size = (((free_mem - DATASET_SIZE - (64U << 20)) / SCRATCHPAD_SIZE) / 32) * 32;

	GPUPtr dataset_gpu(DATASET_SIZE);
	if (!dataset_gpu)
	{
		fprintf(stderr, "Failed to allocate GPU memory for dataset!");
		return false;
	}

	printf("Allocated 2 GB dataset\n");

	// TODO: initialize dataset

	GPUPtr scratchpads_gpu(batch_size * SCRATCHPAD_SIZE);
	if (!scratchpads_gpu)
	{
		fprintf(stderr, "Failed to allocate GPU memory for scratchpads!");
		return false;
	}

	printf("Allocated %zu scratchpads\n", batch_size);

	GPUPtr hashes_gpu(batch_size * HASH_SIZE);
	if (!hashes_gpu)
	{
		fprintf(stderr, "Failed to allocate GPU memory for hashes!");
		return false;
	}

	GPUPtr programs_gpu(batch_size * PROGRAM_SIZE);
	if (!programs_gpu)
	{
		fprintf(stderr, "Failed to allocate GPU memory for programs!");
		return false;
	}

	GPUPtr registers_gpu(batch_size * REGISTERS_SIZE);
	if (!registers_gpu)
	{
		fprintf(stderr, "Failed to allocate GPU memory for registers!");
		return false;
	}

	cudaStatus = cudaMemset(registers_gpu, 0, batch_size * REGISTERS_SIZE);
	if (cudaStatus != cudaSuccess)
	{
		fprintf(stderr, "Failed to initialize GPU memory for registers!");
		return false;
	}

	GPUPtr blockTemplate_gpu(sizeof(blockTemplate));
	if (!blockTemplate_gpu)
	{
		fprintf(stderr, "Failed to allocate GPU memory for block template!");
		return false;
	}

	cudaStatus = cudaMemcpy(blockTemplate_gpu, blockTemplate, sizeof(blockTemplate), cudaMemcpyHostToDevice);
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "Failed to copy block template to GPU: %s\n", cudaGetErrorString(cudaStatus));
		return false;
	}

	cudaStatus = cudaMemGetInfo(&free_mem, &total_mem);
	if (cudaStatus != cudaSuccess)
	{
		fprintf(stderr, "Failed to get free memory info!");
		return false;
	}

	printf("%zu MB free GPU memory left\n", free_mem >> 20);

	time_point<steady_clock> prev_time;

	for (uint32_t nonce = 0, k = 0; nonce < 0xFFFFFFFFUL; nonce += batch_size, ++k)
	{
		if ((k % 16) == 0)
		{
			time_point<steady_clock> cur_time = high_resolution_clock::now();
			if (k > 0)
			{
				const double dt = duration_cast<nanoseconds>(cur_time - prev_time).count() / 1e9;
				printf("%.0f h/s        \r", batch_size * 16 / dt);
			}
			prev_time = cur_time;
		}

		blake2b_initial_hash<sizeof(blockTemplate)><<<batch_size / 32, 32>>>(hashes_gpu, blockTemplate_gpu, nonce);
		cudaStatus = cudaGetLastError();
		if (cudaStatus != cudaSuccess) {
			fprintf(stderr, "blake2b_initial_hash launch failed: %s\n", cudaGetErrorString(cudaStatus));
			return false;
		}

		fillAes1Rx4<SCRATCHPAD_SIZE, true><<<batch_size / 32, 32 * 4>>>(hashes_gpu, scratchpads_gpu, batch_size);
		cudaStatus = cudaGetLastError();
		if (cudaStatus != cudaSuccess) {
			fprintf(stderr, "fillAes1Rx4 launch failed: %s\n", cudaGetErrorString(cudaStatus));
			return false;
		}

		for (size_t i = 0; i < PROGRAM_COUNT; ++i)
		{
			fillAes1Rx4<PROGRAM_SIZE, false><<<batch_size / 32, 32 * 4>>>(hashes_gpu, programs_gpu, batch_size);
			cudaStatus = cudaGetLastError();
			if (cudaStatus != cudaSuccess) {
				fprintf(stderr, "fillAes1Rx4 launch failed: %s\n", cudaGetErrorString(cudaStatus));
				return false;
			}

			initGroupA_registers<<<batch_size / 32, 32>>>(programs_gpu, registers_gpu);

			// TODO: execute VM

			if (i == PROGRAM_COUNT - 1)
			{
				hashAes1Rx4<SCRATCHPAD_SIZE, 192, REGISTERS_SIZE><<<batch_size / 32, 32 * 4>>>(scratchpads_gpu, registers_gpu, batch_size);
				cudaStatus = cudaGetLastError();
				if (cudaStatus != cudaSuccess) {
					fprintf(stderr, "hashAes1Rx4 launch failed: %s\n", cudaGetErrorString(cudaStatus));
					return false;
				}

				blake2b_hash_registers<REGISTERS_SIZE, 32><<<batch_size / 32, 32>>>(hashes_gpu, registers_gpu);
				cudaStatus = cudaGetLastError();
				if (cudaStatus != cudaSuccess) {
					fprintf(stderr, "blake2b_hash_registers launch failed: %s\n", cudaGetErrorString(cudaStatus));
					return false;
				}
			}
			else
			{
				blake2b_hash_registers<REGISTERS_SIZE, 64><<<batch_size / 32, 32>>>(hashes_gpu, registers_gpu);
				cudaStatus = cudaGetLastError();
				if (cudaStatus != cudaSuccess) {
					fprintf(stderr, "blake2b_hash_registers launch failed: %s\n", cudaGetErrorString(cudaStatus));
					return false;
				}
			}
		}

		cudaStatus = cudaDeviceSynchronize();
		if (cudaStatus != cudaSuccess) {
			fprintf(stderr, "cudaDeviceSynchronize returned error code %d!\n", cudaStatus);
			return false;
		}
	}

	return true;
}

void tests()
{
	constexpr size_t NUM_SCRATCHPADS_TEST = 128;
	constexpr size_t NUM_SCRATCHPADS_BENCH = 2048;
	constexpr size_t BLAKE2B_STEP = 1 << 28;

	std::vector<uint8_t> scratchpads(SCRATCHPAD_SIZE * NUM_SCRATCHPADS_TEST * 2);
	std::vector<uint8_t> programs(PROGRAM_SIZE * NUM_SCRATCHPADS_TEST * 2);

	uint64_t hash[NUM_SCRATCHPADS_TEST * 8] = {};
	uint64_t hash2[NUM_SCRATCHPADS_TEST * 8] = {};

	uint8_t registers[NUM_SCRATCHPADS_TEST * REGISTERS_SIZE] = {};
	uint8_t registers2[NUM_SCRATCHPADS_TEST * REGISTERS_SIZE] = {};

	GPUPtr hash_gpu(sizeof(hash));
	if (!hash_gpu) {
		fprintf(stderr, "cudaMalloc failed!");
		return;
	}

	GPUPtr block_template_gpu(sizeof(blockTemplate));
	if (!block_template_gpu) {
		fprintf(stderr, "cudaMalloc failed!");
		return;
	}

	GPUPtr nonce_gpu(sizeof(uint64_t));
	if (!nonce_gpu) {
		fprintf(stderr, "cudaMalloc failed!");
		return;
	}

	GPUPtr states_gpu(sizeof(hash) * NUM_SCRATCHPADS_BENCH);
	if (!states_gpu) {
		return;
	}

	GPUPtr scratchpads_gpu(SCRATCHPAD_SIZE * NUM_SCRATCHPADS_BENCH);
	if (!scratchpads_gpu) {
		fprintf(stderr, "cudaMalloc failed!");
		return;
	}

	GPUPtr programs_gpu(SCRATCHPAD_SIZE * NUM_SCRATCHPADS_TEST);
	if (!programs_gpu) {
		fprintf(stderr, "cudaMalloc failed!");
		return;
	}

	GPUPtr registers_gpu(REGISTERS_SIZE * NUM_SCRATCHPADS_TEST);
	if (!registers_gpu) {
		fprintf(stderr, "cudaMalloc failed!");
		return;
	}

	cudaError_t cudaStatus = cudaMemcpy(block_template_gpu, blockTemplate, sizeof(blockTemplate), cudaMemcpyHostToDevice);
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaMemcpy failed!");
		return;
	}

	{
		blake2b_initial_hash<sizeof(blockTemplate)><<<NUM_SCRATCHPADS_TEST / 32, 32>>>(hash_gpu, block_template_gpu, 0);

		cudaStatus = cudaDeviceSynchronize();
		if (cudaStatus != cudaSuccess) {
			fprintf(stderr, "cudaDeviceSynchronize returned error code %d after launching blake2b_512_double_block_test!\n", cudaStatus);
			return;
		}

		cudaStatus = cudaMemcpy(&hash, hash_gpu, sizeof(hash), cudaMemcpyDeviceToHost);
		if (cudaStatus != cudaSuccess) {
			fprintf(stderr, "cudaMemcpy failed!");
			return;
		}

		for (uint32_t i = 0; i < NUM_SCRATCHPADS_TEST; ++i)
		{
			*(uint32_t*)(blockTemplate + 39) = i;
			blake2b(hash2 + i * 8, 64, blockTemplate, sizeof(blockTemplate), nullptr, 0);
		}

		if (memcmp(hash, hash2, sizeof(hash)) != 0)
		{
			fprintf(stderr, "blake2b_initial_hash test failed!");
			return;
		}

		printf("blake2b_initial_hash test passed\n");
	}

	{
		fillAes1Rx4<SCRATCHPAD_SIZE, true><<<NUM_SCRATCHPADS_TEST / 32, 32 * 4>>>(hash_gpu, scratchpads_gpu, NUM_SCRATCHPADS_TEST);

		cudaStatus = cudaDeviceSynchronize();
		if (cudaStatus != cudaSuccess) {
			fprintf(stderr, "cudaDeviceSynchronize returned error code %d after launching blake2b_512_double_block_test!\n", cudaStatus);
			return;
		}

		cudaStatus = cudaMemcpy(&hash, hash_gpu, sizeof(hash), cudaMemcpyDeviceToHost);
		if (cudaStatus != cudaSuccess) {
			fprintf(stderr, "cudaMemcpy failed!");
			return;
		}

		cudaStatus = cudaMemcpy(scratchpads.data(), scratchpads_gpu, SCRATCHPAD_SIZE * NUM_SCRATCHPADS_TEST, cudaMemcpyDeviceToHost);
		if (cudaStatus != cudaSuccess) {
			fprintf(stderr, "cudaMemcpy failed!");
			return;
		}

		for (int i = 0; i < NUM_SCRATCHPADS_TEST; ++i)
		{
			fillAes1Rx4<false>(hash2 + i * 8, SCRATCHPAD_SIZE, scratchpads.data() + SCRATCHPAD_SIZE * (NUM_SCRATCHPADS_TEST + i));

			if (memcmp(hash + i * 8, hash2 + i * 8, 64) != 0)
			{
				fprintf(stderr, "fillAes1Rx4 test (hash) failed!");
				return;
			}

			const uint8_t* p1 = scratchpads.data() + i * 64;
			const uint8_t* p2 = scratchpads.data() + SCRATCHPAD_SIZE * (NUM_SCRATCHPADS_TEST + i);
			for (int j = 0; j < SCRATCHPAD_SIZE; j += 64)
			{
				if (memcmp(p1 + j * NUM_SCRATCHPADS_TEST, p2 + j, 64) != 0)
				{
					fprintf(stderr, "fillAes1Rx4 test (scratchpad) failed!");
					return;
				}
			}
		}

		printf("fillAes1Rx4 (scratchpads) test passed\n");
	}

	{
		fillAes1Rx4<PROGRAM_SIZE, false><<<NUM_SCRATCHPADS_TEST / 32, 32 * 4 >>>(hash_gpu, programs_gpu, NUM_SCRATCHPADS_TEST);

		cudaStatus = cudaDeviceSynchronize();
		if (cudaStatus != cudaSuccess) {
			fprintf(stderr, "cudaDeviceSynchronize returned error code %d after launching blake2b_512_double_block_test!\n", cudaStatus);
			return;
		}

		cudaStatus = cudaMemcpy(hash, hash_gpu, sizeof(hash), cudaMemcpyDeviceToHost);
		if (cudaStatus != cudaSuccess) {
			fprintf(stderr, "cudaMemcpy failed!");
			return;
		}

		cudaStatus = cudaMemcpy(programs.data(), programs_gpu, PROGRAM_SIZE * NUM_SCRATCHPADS_TEST, cudaMemcpyDeviceToHost);
		if (cudaStatus != cudaSuccess) {
			fprintf(stderr, "cudaMemcpy failed!");
			return;
		}

		for (int i = 0; i < NUM_SCRATCHPADS_TEST; ++i)
		{
			fillAes1Rx4<false>(hash2 + i * 8, PROGRAM_SIZE, programs.data() + PROGRAM_SIZE * (NUM_SCRATCHPADS_TEST + i));

			if (memcmp(hash + i * 8, hash2 + i * 8, 64) != 0)
			{
				fprintf(stderr, "fillAes1Rx4 test (hash) failed!");
				return;
			}

			if (memcmp(programs.data() + i * PROGRAM_SIZE, programs.data() + (NUM_SCRATCHPADS_TEST + i) * PROGRAM_SIZE, PROGRAM_SIZE) != 0)
			{
				fprintf(stderr, "fillAes1Rx4 test (program) failed!");
				return;
			}
		}

		printf("fillAes1Rx4 (programs) test passed\n");
	}
	
	{
		hashAes1Rx4<SCRATCHPAD_SIZE, 192, REGISTERS_SIZE><<<NUM_SCRATCHPADS_TEST / 32, 32 * 4>>>(scratchpads_gpu, registers_gpu, NUM_SCRATCHPADS_TEST);

		cudaStatus = cudaDeviceSynchronize();
		if (cudaStatus != cudaSuccess) {
			fprintf(stderr, "cudaDeviceSynchronize returned error code %d after launching blake2b_512_double_block_test!\n", cudaStatus);
			return;
		}

		cudaStatus = cudaMemcpy(registers, registers_gpu, sizeof(registers), cudaMemcpyDeviceToHost);
		if (cudaStatus != cudaSuccess) {
			fprintf(stderr, "cudaMemcpy failed!");
			return;
		}

		for (int i = 0; i < NUM_SCRATCHPADS_TEST; ++i)
		{
			hashAes1Rx4<false>(scratchpads.data() + SCRATCHPAD_SIZE * (NUM_SCRATCHPADS_TEST + i), SCRATCHPAD_SIZE, registers2 + REGISTERS_SIZE * i + 192);

			if (memcmp(registers + i * REGISTERS_SIZE, registers2 + i * REGISTERS_SIZE, REGISTERS_SIZE) != 0)
			{
				fprintf(stderr, "hashAes1Rx4 test failed!");
				return;
			}
		}

		printf("hashAes1Rx4 test passed\n");
	}

	{
		blake2b_hash_registers<REGISTERS_SIZE, 32><<<NUM_SCRATCHPADS_TEST / 32, 32>>>(hash_gpu, registers_gpu);
		cudaStatus = cudaGetLastError();
		if (cudaStatus != cudaSuccess) {
			fprintf(stderr, "blake2b_hash_registers launch failed: %s\n", cudaGetErrorString(cudaStatus));
			return;
		}

		cudaStatus = cudaMemcpy(&hash, hash_gpu, sizeof(hash), cudaMemcpyDeviceToHost);
		if (cudaStatus != cudaSuccess) {
			fprintf(stderr, "cudaMemcpy failed!");
			return;
		}

		for (uint32_t i = 0; i < NUM_SCRATCHPADS_TEST; ++i)
		{
			blake2b(hash2 + i * 4, 32, registers2 + i * REGISTERS_SIZE, REGISTERS_SIZE, nullptr, 0);
		}

		if (memcmp(hash, hash2, NUM_SCRATCHPADS_TEST * 32) != 0)
		{
			fprintf(stderr, "blake2b_hash_registers (32 byte hash) test failed!");
			return;
		}

		printf("blake2b_hash_registers (32 byte hash) test passed\n");
	}

	{
		blake2b_hash_registers<REGISTERS_SIZE, 64><<<NUM_SCRATCHPADS_TEST / 32, 32>>>(hash_gpu, registers_gpu);
		cudaStatus = cudaGetLastError();
		if (cudaStatus != cudaSuccess) {
			fprintf(stderr, "blake2b_hash_registers launch failed: %s\n", cudaGetErrorString(cudaStatus));
			return;
		}

		cudaStatus = cudaMemcpy(&hash, hash_gpu, sizeof(hash), cudaMemcpyDeviceToHost);
		if (cudaStatus != cudaSuccess) {
			fprintf(stderr, "cudaMemcpy failed!");
			return;
		}

		for (uint32_t i = 0; i < NUM_SCRATCHPADS_TEST; ++i)
		{
			blake2b(hash2 + i * 8, 64, registers2 + i * REGISTERS_SIZE, REGISTERS_SIZE, nullptr, 0);
		}

		if (memcmp(hash, hash2, NUM_SCRATCHPADS_TEST * 64) != 0)
		{
			fprintf(stderr, "blake2b_hash_registers (64 byte hash) test failed!");
			return;
		}

		printf("blake2b_hash_registers (64 byte hash) test passed\n");
	}

	time_point<steady_clock> start_time = high_resolution_clock::now();

	for (int i = 0; i < 100; ++i)
	{
		printf("Benchmarking fillAes1Rx4 %d/100", i + 1);
		if (i > 0)
		{
			const double dt = duration_cast<nanoseconds>(high_resolution_clock::now() - start_time).count() / 1e9;
			printf(", %.0f scratchpads/s", (i * NUM_SCRATCHPADS_BENCH * 10) / dt);
		}
		printf("\r");

		for (int j = 0; j < 10; ++j)
		{
			fillAes1Rx4<SCRATCHPAD_SIZE, true><<<NUM_SCRATCHPADS_BENCH / 32, 32 * 4>>>(states_gpu, scratchpads_gpu, NUM_SCRATCHPADS_BENCH);

			cudaStatus = cudaGetLastError();
			if (cudaStatus != cudaSuccess) {
				fprintf(stderr, "fillAes1Rx4 launch failed: %s\n", cudaGetErrorString(cudaStatus));
				return;
			}
		}

		cudaStatus = cudaDeviceSynchronize();
		if (cudaStatus != cudaSuccess) {
			fprintf(stderr, "cudaDeviceSynchronize returned error code %d after launching fillAes1Rx4!\n", cudaStatus);
			return;
		}
	}
	printf("\n");

	start_time = high_resolution_clock::now();

	for (int i = 0; i < 100; ++i)
	{
		printf("Benchmarking hashAes1Rx4 %d/100", i + 1);
		if (i > 0)
		{
			const double dt = duration_cast<nanoseconds>(high_resolution_clock::now() - start_time).count() / 1e9;
			printf(", %.0f scratchpads/s", (i * NUM_SCRATCHPADS_BENCH * 10) / dt);
		}
		printf("\r");

		for (int j = 0; j < 10; ++j)
		{
			hashAes1Rx4<SCRATCHPAD_SIZE, 0, 64><<<NUM_SCRATCHPADS_BENCH / 32, 32 * 4>>>(scratchpads_gpu, states_gpu, NUM_SCRATCHPADS_BENCH);

			cudaStatus = cudaGetLastError();
			if (cudaStatus != cudaSuccess) {
				fprintf(stderr, "hashAes1Rx4 launch failed: %s\n", cudaGetErrorString(cudaStatus));
				return;
			}
		}

		cudaStatus = cudaDeviceSynchronize();
		if (cudaStatus != cudaSuccess) {
			fprintf(stderr, "cudaDeviceSynchronize returned error code %d after launching hashAes1Rx4!\n", cudaStatus);
			return;
		}
	}
	printf("\n");

	cudaStatus = cudaMemcpy(block_template_gpu, blockTemplate, sizeof(blockTemplate), cudaMemcpyHostToDevice);
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaMemcpy failed!");
		return;
	}

	start_time = high_resolution_clock::now();

	for (uint64_t start_nonce = 0; start_nonce < BLAKE2B_STEP * 100; start_nonce += BLAKE2B_STEP)
	{
		printf("Benchmarking blake2b_512_single_block %llu/100", (start_nonce + BLAKE2B_STEP) / BLAKE2B_STEP);
		if (start_nonce > 0)
		{
			const double dt = duration_cast<nanoseconds>(high_resolution_clock::now() - start_time).count() / 1e9;
			printf(", %.2f MH/s", start_nonce / dt / 1e6);
		}
		printf("\r");

		cudaStatus = cudaMemset(nonce_gpu, 0, sizeof(uint64_t));
		if (cudaStatus != cudaSuccess) {
			fprintf(stderr, "cudaMemcpy failed!");
			return;
		}

		void* out = nonce_gpu;
		blake2b_512_single_block_bench<sizeof(blockTemplate)><<<BLAKE2B_STEP / 256, 256>>>((uint64_t*) out, block_template_gpu, start_nonce);

		cudaStatus = cudaGetLastError();
		if (cudaStatus != cudaSuccess) {
			fprintf(stderr, "blake2b_512_single_block_bench launch failed: %s\n", cudaGetErrorString(cudaStatus));
			return;
		}

		cudaStatus = cudaDeviceSynchronize();
		if (cudaStatus != cudaSuccess) {
			fprintf(stderr, "cudaDeviceSynchronize returned error code %d after launching blake2b_512_single_block_bench!\n", cudaStatus);
			return;
		}

		uint64_t nonce;
		cudaStatus = cudaMemcpy(&nonce, nonce_gpu, sizeof(nonce), cudaMemcpyDeviceToHost);
		if (cudaStatus != cudaSuccess) {
			fprintf(stderr, "cudaMemcpy failed!");
			return;
		}

		if (nonce)
		{
			*(uint64_t*)(blockTemplate) = nonce;
			blake2b(hash, 64, blockTemplate, sizeof(blockTemplate), nullptr, 0);
			printf("nonce = %llu, hash[7] = %016llx                  \n", nonce, hash[7]);
		}
	}
	printf("\n");

	start_time = high_resolution_clock::now();

	for (uint64_t start_nonce = 0; start_nonce < BLAKE2B_STEP * 100; start_nonce += BLAKE2B_STEP)
	{
		printf("Benchmarking blake2b_512_double_block %llu/100", (start_nonce + BLAKE2B_STEP) / BLAKE2B_STEP);
		if (start_nonce > 0)
		{
			const double dt = duration_cast<nanoseconds>(high_resolution_clock::now() - start_time).count() / 1e9;
			printf(", %.2f MH/s", start_nonce / dt / 1e6);
		}
		printf("\r");

		const uint64_t zero = 0;
		cudaStatus = cudaMemcpy(nonce_gpu, &zero, sizeof(zero), cudaMemcpyHostToDevice);
		if (cudaStatus != cudaSuccess) {
			fprintf(stderr, "cudaMemcpy failed!");
			return;
		}

		void* out = nonce_gpu;
		blake2b_512_double_block_bench<REGISTERS_SIZE><<<BLAKE2B_STEP / 256, 256>>>((uint64_t*) out, registers_gpu, start_nonce);

		cudaStatus = cudaGetLastError();
		if (cudaStatus != cudaSuccess) {
			fprintf(stderr, "blake2b_512_double_block_bench launch failed: %s\n", cudaGetErrorString(cudaStatus));
			return;
		}

		cudaStatus = cudaDeviceSynchronize();
		if (cudaStatus != cudaSuccess) {
			fprintf(stderr, "cudaDeviceSynchronize returned error code %d after launching blake2b_512_double_block_bench!\n", cudaStatus);
			return;
		}

		uint64_t nonce;
		cudaStatus = cudaMemcpy(&nonce, nonce_gpu, sizeof(nonce), cudaMemcpyDeviceToHost);
		if (cudaStatus != cudaSuccess) {
			fprintf(stderr, "cudaMemcpy failed!");
			return;
		}

		if (nonce)
		{
			*(uint64_t*)(registers) = nonce;
			blake2b(hash, 64, registers, REGISTERS_SIZE, nullptr, 0);
			printf("nonce = %llu, hash[7] = %016llx                  \n", nonce, hash[7]);
		}
	}
	printf("\n");
}