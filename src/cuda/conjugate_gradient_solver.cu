#include <cuda.h> 
#include <cuda_runtime.h>
#include <stdio.h>
#include <assert.h>
#include "conjugate_gradient_solver.hh"
#include <math.h>
#include <cmath>
#include <iostream>
#include <cfloat>
__global__ void dbgprint(int recogn, realw* a, int index)
{
	printf("\n%d,value: %e\n",recogn,a[index]);
}
/*

*/

__global__ void cureduce(realw *g_odata, realw *g_idata, int *mpirepeat,  int size, int myrank) 
{ 
	/** reduce operation*/
	extern __shared__ realw sdata[];
	// each thread loads one element from global to shared mem
	unsigned int tid = threadIdx.x;
	unsigned int i = blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; 
	unsigned int bid = blockIdx.y*gridDim.x + blockIdx.x;
	sdata[tid] = 0.f;
	
	if(i < size) sdata[tid] = g_idata[i]*(-1.0)*(realw)mpirepeat[i/3];	//we use MPI_repeat to exclude repeating node at MPI interface

	__syncthreads();
	// // do reduction in shared mem
	for (unsigned int s=1; s < blockDim.x; s *= 2) 
	{
		int index = 2 * s * tid;
		if (index < blockDim.x) 
		{ 
			sdata[index] += sdata[index + s];
		}
		__syncthreads(); 
	}

	if (tid == 0)
	{
	//	printf("\n%dsdata[0]=%f\n",myrank,sdata[0]);
		atomicAdd(g_odata, sdata[0]);
	}/** this step can be further optimized*/
}
/*
*/
__global__ void vecMul(realw* a, realw* b, realw* results,int size,int myrank)
{

	int id = threadIdx.x + blockIdx.x*blockDim.x + blockIdx.y*gridDim.x*blockDim.x;
	if(id >= size) return;
	results[id] = a[id] * b[id];

}
__global__ void addMass(realw* d_force, realw* d_displ, realw* rmass, realw coeff, int size,int myrank)
{

	int id = threadIdx.x + blockIdx.x*blockDim.x + blockIdx.y*gridDim.x*blockDim.x;
	if(id >= size) return;
	d_force[3*id] += d_displ[3*id]*1.0/rmass[id]*coeff;
	d_force[3*id+1] += d_displ[3*id+1]*1.0/rmass[id]*coeff;
	d_force[3*id+2] += d_displ[3*id+2]*1.0/rmass[id]*coeff;

}
__global__ void inttofloat(realw* a, int* b ,int size,int myrank)
{

	int id = threadIdx.x + blockIdx.x*blockDim.x + blockIdx.y*gridDim.x*blockDim.x;
	if(id >= size) return;
	a[id] = (realw)b[id]; 
	//a[id*3] = b[id];
	//a[id*3+1] = 0.0;
	//a[id*3+2] = 0.0;

}


__global__ void vecMul2(realw* a, int* b, realw* results,int size,int myrank)
{

	int id = threadIdx.x + blockIdx.x*blockDim.x + blockIdx.y*gridDim.x*blockDim.x;
	if(id >= size) return;
	for(int i = 0 ; i < 3 ; i++)
	{	
		results[3*id+i] = a[3*id+i] * (-1.0) * b[id] ;
	}

}

__global__ void reset(realw* a, int size)
{

	int id = threadIdx.x + blockIdx.x*blockDim.x + blockIdx.y*gridDim.x*blockDim.x;
	if(id >= size) return;
	a[id] = 0.0f;

}

__global__ void vecAdd(realw* a, realw* b, realw i, realw* results, int size)
{
	int id = threadIdx.x + blockIdx.x*blockDim.x + blockIdx.y*gridDim.x*blockDim.x;

	if(id >= size) return;
//	if(isinf(a[id])) printf("Add: wrong value in a!,id=%d, value=%f",id,a[id]);

//	if(isinf(b[id])) printf("Add: wrong value in b!,id=%d, value=%f",id,b[id]);
	results[id] = a[id] + i * b[id]; 
    //if(id==0) printf("\ni value :%f\n",i);
}

conjugate_gradient::conjugate_gradient(int NELE, realw* pdis, realw* pload, int* Xsetfalse, int* AXsetfalse, realw* gpu_displ, realw* gpu_force,  int precon ,int proc_num, realw* recorder,int* MPI_repeat, realw* h_restri_op, realw* d_rmass)
{
	int num_blocks_x, num_blocks_y;
	int size;

	int i;
	this->NSPEC = NELE;
	get_blocks_xy((int)ceil((double)(3*NSPEC)/1024.0),&num_blocks_x, &num_blocks_y);
	dim3 grid(num_blocks_x,num_blocks_y);
	dim3 threads(1024,1,1);

	/** reference to the outside array*/
	this->h_displ = pdis;
	this->h_load = pload;
	this->h_rec = recorder;
	this->deltat_sq_inv = 0.0;
	/** these two cpu vectors are not used */
	this->myrank = proc_num;
	this->h_MASKX = Xsetfalse;
	this->h_MASKAX = AXsetfalse;
	this->h_Mprecon = new realw[3*NSPEC];
	this->h_blocksum = new realw[num_blocks_x*num_blocks_y];
	this->rmass = d_rmass;

	size = NSPEC*3*sizeof(realw);

	print_CUDA_error_if_any(cudaMalloc((void**)(&(this->d_pdire)), size), 50001);
	print_CUDA_error_if_any(cudaMalloc((void**)(&(this->d_residue)), size), 50002);
	print_CUDA_error_if_any(cudaMalloc((void**)(&(this->d_tmp)), size), 50003);
	print_CUDA_error_if_any(cudaMalloc((void**)(&(this->d_tmp2)), size), 50004);
	print_CUDA_error_if_any(cudaMalloc((void**)(&(this->d_precon)), size), 50005);
	print_CUDA_error_if_any(cudaMalloc((void**)(&(this->d_sum)),sizeof(realw)),50006);
	print_CUDA_error_if_any(cudaMalloc((void**)(&(this->d_norm)),sizeof(realw)),50007);
//	print_CUDA_error_if_any(cudaMalloc((void**)(&(this->d_blocksum)),sizeof(realw)*num_blocks_x*num_blocks_y),50041);
	print_CUDA_error_if_any(cudaMalloc((void**)(&(this->d_MASKAX)), NSPEC*3*sizeof(int)), 50008);
	print_CUDA_error_if_any(cudaMalloc((void**)(&(this->d_MASKX)), NSPEC*3*sizeof(int)), 50009);
	print_CUDA_error_if_any(cudaMalloc((void**)(&(this->d_load)), NSPEC*3*sizeof(realw)), 50010);
	print_CUDA_error_if_any(cudaMalloc((void**)(&(this->d_MPI_repeat)), NSPEC*sizeof(int)), 50011);
	print_CUDA_error_if_any(cudaMalloc((void**)(&(this->d_restri_op)), NSPEC*sizeof(realw)), 50012);



	print_CUDA_error_if_any(cudaMemset(this->d_sum, 0.f , sizeof(realw)) ,50013);
	print_CUDA_error_if_any(cudaMemset(this->d_norm, 0.f , sizeof(realw)) ,50014);
	print_CUDA_error_if_any(cudaMemset(this->d_tmp, 0.f , sizeof(realw)) ,50015);
	print_CUDA_error_if_any(cudaMemcpy(this->d_MASKX, this->h_MASKX, NSPEC*3*sizeof(int), cudaMemcpyHostToDevice),50016);
	print_CUDA_error_if_any(cudaMemcpy(this->d_MASKAX, this->h_MASKAX, NSPEC*3*sizeof(int), cudaMemcpyHostToDevice),50017);
	print_CUDA_error_if_any(cudaMemcpy(this->d_MPI_repeat, MPI_repeat, NSPEC*sizeof(int),cudaMemcpyHostToDevice),50018);
	print_CUDA_error_if_any(cudaMemcpy(this->d_restri_op, h_restri_op, NSPEC*sizeof(realw),cudaMemcpyHostToDevice),50019);



	double start = get_time();
	print_CUDA_error_if_any(cudaMemcpy(this->d_load, this->h_load, NSPEC*3*sizeof(realw), cudaMemcpyHostToDevice),50015);
	/** gpu vectors */
	this->d_displ = gpu_displ;
	this->d_force = gpu_force;
	/** compute diagonal preconditioner */
	if(precon)
		this->compute_precon(); /** calls the cpu subroutine to compute diagonal elements */
	print_CUDA_error_if_any(cudaMemcpy(this->d_precon, this->h_Mprecon, NSPEC*3*sizeof(realw), cudaMemcpyHostToDevice),50005);

	reset<<<grid,threads>>>(this->d_force,this->NSPEC*3);
	this->compute_forces(this->d_displ);

	vecAdd<<<grid,threads>>>(this->d_load, this->d_force,-1.f, this->d_residue, this->NSPEC*3);/**r=b-Ax*/

	vecMul<<<grid,threads>>>(this->d_residue, this->d_precon, this->d_pdire, this->NSPEC*3,myrank);/** calculate P = M*r */

//	this->compute_precond(this->d_residue, this->d_pdire);


	vecMul<<<grid,threads>>>(this->d_pdire, this->d_residue, this->d_tmp, this->NSPEC*3,myrank);

	print_CUDA_error_if_any(cudaMemset(this->d_sum, 0.f , sizeof(realw)) ,50006);
	
	cureduce<<<grid,threads,1024*sizeof(realw)>>>(this->d_sum, this->d_tmp, this->d_MPI_repeat, this->NSPEC*3, myrank);

	print_CUDA_error_if_any(cudaMemcpy(&(this->h_sum),this->d_sum,sizeof(realw),cudaMemcpyDeviceToHost),50038);/** copy local sum from gpu to cpu*/

	print_CUDA_error_if_any(cudaMemcpy((this->h_rec),this->d_pdire,sizeof(realw)*3*NSPEC,cudaMemcpyDeviceToHost),50038);/** copy local sum from gpu to cpu*/


	
//	printf("\nlocal sum : %d,%e\n",myrank,this->h_sum);
	sum_all_all_cr_(&(this->h_sum),&(this->h_sum_all));

	printf("\nglobal sum: %d,%e\n",myrank,this->h_sum_all);
	this->h_normold = this->h_sum_all;
	this->r0 = this->h_normold; /** record the initial residue*/

}
conjugate_gradient::~conjugate_gradient()
{
	std::cout<< "I am destroyed!!!"<<std::endl;
}

void conjugate_gradient::reinit(realw deltat_sq_inv_in)
{
	int num_blocks_x, num_blocks_y;

	get_blocks_xy((int)ceil((double)(3*NSPEC)/1024.0),&num_blocks_x, &num_blocks_y);
	dim3 grid(num_blocks_x,num_blocks_y);
	dim3 threads(1024,1,1);
	this->deltat_sq_inv = deltat_sq_inv_in;
	std::cout <<"\ndeltat_square:" <<deltat_sq_inv_in << std::endl;

	reset<<<grid,threads>>>(this->d_force,this->NSPEC*3);
	this->compute_forces(this->d_displ);

	vecAdd<<<grid,threads>>>(this->d_load, this->d_force,-1.f, this->d_residue, this->NSPEC*3);/**r=b-Ax*/

//	this->compute_precond(this->d_residue);

	vecMul<<<grid,threads>>>(this->d_residue, this->d_precon, this->d_pdire, this->NSPEC*3,myrank);/** calculate P = M*r */

	vecMul<<<grid,threads>>>(this->d_pdire, this->d_residue, this->d_tmp, this->NSPEC*3,myrank);

	//vecMul2<<<grid,threads>>>(this->d_tmp, this->d_MPI_repeat, this->d_tmp, this->NSPEC,myrank);

	print_CUDA_error_if_any(cudaMemset(this->d_sum, 0.f , sizeof(realw)) ,50006);
	
	cureduce<<<grid,threads,1024*sizeof(realw)>>>(this->d_sum, this->d_tmp, this->d_MPI_repeat,  this->NSPEC*3, myrank);

	print_CUDA_error_if_any(cudaMemcpy(&(this->h_sum),this->d_sum,sizeof(realw),cudaMemcpyDeviceToHost),50038);/** copy local sum from gpu to cpu*/

	print_CUDA_error_if_any(cudaMemcpy((this->h_rec),this->d_pdire,sizeof(realw)*3*NSPEC,cudaMemcpyDeviceToHost),50038);/** copy local sum from gpu to cpu*/


	
	sum_all_all_cr_(&(this->h_sum),&(this->h_sum_all));

	printf("\nglobal sum: %d,%e\n",myrank,this->h_sum_all);
	this->h_normold = this->h_sum_all;
	this->r0 = this->h_normold;

}



void conjugate_gradient::compute_precon()
{
	compute_diagonal_(this->h_Mprecon); /** fortran subroutine : ../specfem3d/compute_diagonal.f90 */ 
	for(int i = 0; i < 3 * NSPEC ; i++) 
	{
		this->h_Mprecon[i] = 1.f/(this->h_Mprecon[i]);
	}
}

void conjugate_gradient::checkfield()
{
	this->gpu_init();
}

	
void conjugate_gradient::gpu_init()
{
	int num_blocks_x, num_blocks_y;
	get_blocks_xy((int)ceil((double)(3*NSPEC)/1024.0),&num_blocks_x, &num_blocks_y);
	dim3 grid(num_blocks_x,num_blocks_y);
	dim3 threads(1024,1,1);

}

void conjugate_gradient::sum()
{
	int num_blocks_x, num_blocks_y;
	get_blocks_xy((int)ceil((double)(3*NSPEC)/1024.0),&num_blocks_x, &num_blocks_y);
	dim3 grid(num_blocks_x,num_blocks_y);
	std::cout<<num_blocks_x<<" "<<num_blocks_y << std::endl;
	dim3 threads(1024,1,1);
    cureduce<<<grid,threads,1024*sizeof(realw)>>>(this->d_blocksum, this->d_displ, this->d_MPI_repeat, this->NSPEC*3,myrank);
	print_CUDA_error_if_any(cudaMemcpy(&(this->h_sum),this->d_sum,sizeof(realw),cudaMemcpyDeviceToHost),50008);
//	printf("\n the sum of the array: %f::%d\n",(this->h_sum),this->NSPEC);

}

void conjugate_gradient::compute_forces_call()
{
	this->compute_forces(this->d_displ);
}

void conjugate_gradient::compute_forces(realw* displ_field)
{
	int num_blocks_x, num_blocks_y;
	get_blocks_xy((int)ceil((double)(NSPEC)/1024.0),&num_blocks_x, &num_blocks_y);
	dim3 grid(num_blocks_x,num_blocks_y);
	dim3 threads(1024,1,1);


	compute_fault_gpu_(this->d_force, displ_field, this->d_MASKX, this->d_MASKAX);
	addMass<<<grid, threads>>>(this->d_force, displ_field, this->rmass, this->deltat_sq_inv,this->NSPEC, this->myrank );
	



}


void conjugate_gradient::compute_forces_local(realw* displ_field)
{

	compute_fault_gpu_local_(this->d_force, displ_field, this->d_MASKX, this->d_MASKAX);


}

void conjugate_gradient::get_field_from_gpu()
{
	int num_blocks_x, num_blocks_y;

	get_blocks_xy((int)ceil((double)(3*NSPEC)/1024.0),&num_blocks_x, &num_blocks_y);
	dim3 grid(num_blocks_x,num_blocks_y);
	dim3 threads(1024,1,1);

	
//inttofloat<<<grid,threads>>>(this->d_tmp, this->d_MASKAX,3*NSPEC,this->myrank);
	inttofloat<<<grid,threads>>>(this->d_tmp, this->d_MASKAX, 3*NSPEC, this->myrank);
	print_CUDA_error_if_any(cudaMemcpy(this->d_displ, this->d_tmp, 3*NSPEC*sizeof(realw), cudaMemcpyDeviceToDevice),99999);
}

void conjugate_gradient::compute_precond(realw* d_field, realw* re_field)
{

	int num_blocks_x, num_blocks_y;
	get_blocks_xy((int)ceil((double)(3*NSPEC)/1024.0),&num_blocks_x, &num_blocks_y);
	dim3 grid(num_blocks_x,num_blocks_y);
	dim3 threads(1024,1,1);


	cudaMemset(re_field, 0, 3*NSPEC*sizeof(realw));
	for(int i =0 ; i < 10; i++)
	{
		cudaMemset(this->d_force, 0, 3*NSPEC*sizeof(realw));
		this->compute_forces_local(re_field);
		vecAdd<<<grid,threads>>>(d_field, this->d_force, 1.0, this->d_tmp2, this->NSPEC*3);
		vecMul<<<grid,threads>>>(this->d_tmp2, this->d_precon, this->d_tmp2, this->NSPEC*3,myrank);
		vecAdd<<<grid,threads>>>(this->d_tmp2, re_field, 1.0, re_field, this->NSPEC*3);
	}
}

void conjugate_gradient::update_val_dire()
{
	realw alpha,beta;
	int num_blocks_x, num_blocks_y,i;
	get_blocks_xy((int)ceil((double)(3*NSPEC)/1024.0),&num_blocks_x, &num_blocks_y);
	dim3 grid(num_blocks_x,num_blocks_y);
	dim3 threads(1024,1,1);


	reset<<<grid,threads>>>(this->d_force,this->NSPEC*3);
	this->compute_forces(this->d_pdire); /** this->d_force = K*this->d_pdire*/


	vecMul<<<grid, threads>>>(this->d_pdire, this->d_force, this->d_tmp, this->NSPEC*3,myrank);



	print_CUDA_error_if_any(cudaMemset(this->d_sum, 0.f , sizeof(realw)) ,50006);
	
	cureduce<<<grid, threads, 1024*sizeof(realw)>>>(this->d_sum, this->d_tmp, this->d_MPI_repeat, this->NSPEC*3,myrank);

	print_CUDA_error_if_any(cudaMemcpy(&(this->h_sum),this->d_sum,sizeof(realw),cudaMemcpyDeviceToHost),50037);/** copy local sum from gpu to cpu*/

	sum_all_all_cr_(&(this->h_sum),&(this->h_sum_all));

	assert(this->h_sum_all != 0.0f);
	alpha = this->h_normold/this->h_sum_all;

	if(myrank == 0) printf("\nalpha : %f\n",alpha);
	vecAdd<<<grid,threads>>>(this->d_displ,this->d_pdire, alpha, this->d_displ, this->NSPEC*3);


	vecAdd<<<grid,threads>>>(this->d_residue, this->d_force, -alpha,this->d_residue, this->NSPEC*3);


	vecMul<<<grid,threads>>>(this->d_residue, this->d_residue, this->d_tmp, this->NSPEC*3, myrank);

	vecMul<<<grid,threads>>>(this->d_tmp, this->d_precon, this->d_tmp,this->NSPEC*3,myrank);
//	this->compute_precond(this->d_residue, this->d_tmp);

//	vecMul<<<grid,threads>>>(this->d_tmp, this->d_residue, this->d_tmp, this->NSPEC*3, myrank);


	print_CUDA_error_if_any(cudaMemset(this->d_sum, 0.f , sizeof(realw)) ,50006);
	
	cureduce<<<grid,threads,1024*sizeof(realw)>>>(this->d_sum, this->d_tmp, this->d_MPI_repeat, this->NSPEC*3,myrank); 

	print_CUDA_error_if_any(cudaMemcpy(&(this->h_sum),this->d_sum,sizeof(realw),cudaMemcpyDeviceToHost),50038);/** copy local sum from gpu to cpu*/

	sum_all_all_cr_(&(this->h_sum),&(this->h_sum_all));

	assert(this->h_sum_all !=0.0f);
	beta = h_sum_all / h_normold;


	h_normold = h_sum_all;

	if(myrank == 0) printf("\n normnew GPU: %E\n",h_normold);

	vecMul<<<grid,threads>>>(this->d_residue, this->d_precon, this->d_tmp, this->NSPEC*3,myrank);




	vecAdd<<<grid,threads>>>(this->d_tmp, this->d_pdire, beta , this->d_pdire, this->NSPEC*3);

   

}
void conjugate_gradient::solve(realw tolerance)
{
	int iter = 0;
	while(this->h_normold > tolerance*this->r0 && iter < 4000)
	{
		this->update_val_dire();
		iter++;
	}
	if(this->myrank == 0) std::cout<< "\nbing: number of iterations: "<< iter << std::endl;
	return;


}

