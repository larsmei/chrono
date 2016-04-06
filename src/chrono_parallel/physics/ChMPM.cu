#include "chrono_parallel/physics/ChMPM.cuh"
#include "chrono_parallel/physics/MPMUtils.h"
#include "chrono_parallel/ChCudaHelper.cuh"
#include "chrono_parallel/ChGPUVector.cuh"
#include "thirdparty/cub/cub.cuh"
#include "chrono_parallel/math/matrixf.cuh"

namespace chrono {

struct Bounds {
    float minimum[3];
    float maximum[3];
};

float3 min_bounding_point;
float3 max_bounding_point;

MPM_Settings host_settings;

std::vector<int> particle_node_mapping;
std::vector<int> node_particle_mapping;
std::vector<int> node_start_index;
std::vector<int> particle_number;
uint num_mpm_nodes_active;
std::vector<Mat33f> volume_Ap_Fe_transpose;

// GPU Things
float3* lower_bound;
float3* upper_bound;

gpu_vector<float> pos, vel, JE_JP;
gpu_vector<float> node_mass;
gpu_vector<float> marker_volume;
gpu_vector<float> grid_vel, delta_v;
gpu_vector<float> rhs;
gpu_vector<Mat33f> marker_Fe, marker_Fe_hat, marker_Fp, marker_delta_F, PolarR, PolarS;
gpu_vector<float> old_vel_node_mpm;
gpu_vector<float> ml, mg, mg_p, ml_p;
gpu_vector<float> dot_g_proj_norm;
gpu_vector<float> marker_plasticity;
CUDA_CONSTANT MPM_Settings device_settings;
CUDA_CONSTANT Bounds system_bounds;

cudaEvent_t start;
cudaEvent_t stop;
float time_measured = 0;
/////// BB Constants
__device__ float alpha = 0.0001;
__device__ float dot_ms_ms = 0;
__device__ float dot_ms_my = 0;
__device__ float dot_my_my = 0;

#define a_min 1e-13
#define a_max 1e13
#define neg_BB1_fallback 0.11
#define neg_BB2_fallback 0.12

#define LOOP_TWO_RING_GPUSP(X)                                                                                         \
    cx = GridCoord(xix, inv_bin_edge, system_bounds.minimum[0]);                                                       \
    cy = GridCoord(xiy, inv_bin_edge, system_bounds.minimum[1]);                                                       \
    cz = GridCoord(xiz, inv_bin_edge, system_bounds.minimum[2]);                                                       \
    for (int i = cx - 2; i <= cx + 2; ++i) {                                                                           \
        for (int j = cy - 2; j <= cy + 2; ++j) {                                                                       \
            for (int k = cz - 2; k <= cz + 2; ++k) {                                                                   \
                int current_node = GridHash(i, j, k, device_settings.bins_per_axis_x, device_settings.bins_per_axis_y, \
                                            device_settings.bins_per_axis_z);                                          \
                float current_node_locationx = i * bin_edge + system_bounds.minimum[0];                                \
                float current_node_locationy = j * bin_edge + system_bounds.minimum[1];                                \
                float current_node_locationz = k * bin_edge + system_bounds.minimum[2];                                \
                X                                                                                                      \
            }                                                                                                          \
        }                                                                                                              \
    }
//////========================================================================================================================================================================
////

void CUDA_HOST_DEVICE WeakEqual(const float& x, const float& y, float COMPARE_EPS = FLT_EPSILON) {
    if (fabsf(x - y) > COMPARE_EPS) {
        printf("%f does not equal %f %.20e\n", x, y, fabsf(x - y));
        // exit(1);
    }
}

void CUDA_HOST_DEVICE WeakEqual(const Mat33f& a, const Mat33f& b, float COMPARE_EPS = FLT_EPSILON) {
    WeakEqual(a[0], b[0], COMPARE_EPS);
    WeakEqual(a[1], b[1], COMPARE_EPS);
    WeakEqual(a[2], b[2], COMPARE_EPS);
    WeakEqual(a[3], b[3], COMPARE_EPS);
    WeakEqual(a[4], b[4], COMPARE_EPS);
    WeakEqual(a[5], b[5], COMPARE_EPS);
    WeakEqual(a[6], b[6], COMPARE_EPS);
    WeakEqual(a[7], b[7], COMPARE_EPS);
    WeakEqual(a[8], b[8], COMPARE_EPS);
}

CUDA_GLOBAL void kComputeBounds(const float* pos,  // input
                                float3* lower,     // output
                                float3* upper      // output
                                ) {
    typedef cub::BlockReduce<float3, num_threads_per_block> BlockReduce;

    __shared__ typename BlockReduce::TempStorage temp_storage;

    const int block_start = blockDim.x * blockIdx.x;
    const int num_valid = min(device_settings.num_mpm_markers - block_start, blockDim.x);

    const int index = block_start + threadIdx.x;
    if (index < device_settings.num_mpm_markers) {
        float3 data = make_float3(pos[index * 3 + 0], pos[index * 3 + 1], pos[index * 3 + 2]);
        float3 blockUpper = BlockReduce(temp_storage).Reduce(data, float3Max(), num_valid);
        __syncthreads();
        float3 blockLower = BlockReduce(temp_storage).Reduce(data, float3Min(), num_valid);
        if (threadIdx.x == 0) {
            AtomicMax(upper, blockUpper);
            AtomicMin(lower, blockLower);
        }
    }
}
////========================================================================================================================================================================
CUDA_GLOBAL void kRasterize(const float* sorted_pos,  // input
                            const float* sorted_vel,  // input
                            float* grid_mass,         // output
                            float* grid_vel) {        // output
    const int p = blockIdx.x * blockDim.x + threadIdx.x;
    if (p < device_settings.num_mpm_markers) {
        const float xix = sorted_pos[p * 3 + 0];
        const float xiy = sorted_pos[p * 3 + 1];
        const float xiz = sorted_pos[p * 3 + 2];

        const float vix = sorted_vel[p * 3 + 0];
        const float viy = sorted_vel[p * 3 + 1];
        const float viz = sorted_vel[p * 3 + 2];

        int cx, cy, cz;
        const float bin_edge = device_settings.bin_edge;
        const float inv_bin_edge = device_settings.inv_bin_edge;

        LOOP_TWO_RING_GPUSP(  //

            float weight = N((xix - current_node_locationx) * inv_bin_edge) *
                           N((xiy - current_node_locationy) * inv_bin_edge) *
                           N((xiz - current_node_locationz) * inv_bin_edge) * device_settings.mass;

            atomicAdd(&grid_mass[current_node], weight);  //
            atomicAdd(&grid_vel[current_node * 3 + 0], weight * vix);
            atomicAdd(&grid_vel[current_node * 3 + 1], weight * viy);
            atomicAdd(&grid_vel[current_node * 3 + 2], weight * viz);)
    }
}
CUDA_GLOBAL void kRasterize(const float* sorted_pos,  // input
                            float* grid_mass) {       // output
    const int p = blockIdx.x * blockDim.x + threadIdx.x;
    if (p < device_settings.num_mpm_markers) {
        const float xix = sorted_pos[p * 3 + 0];
        const float xiy = sorted_pos[p * 3 + 1];
        const float xiz = sorted_pos[p * 3 + 2];
        int cx, cy, cz;
        const float bin_edge = device_settings.bin_edge;
        const float inv_bin_edge = device_settings.inv_bin_edge;

        LOOP_TWO_RING_GPUSP(  //
            float weight = N((xix - current_node_locationx) * inv_bin_edge) *
                           N((xiy - current_node_locationy) * inv_bin_edge) *
                           N((xiz - current_node_locationz) * inv_bin_edge) * device_settings.mass;
            atomicAdd(&grid_mass[current_node], weight);  //
            )
    }
}
//
////========================================================================================================================================================================
//
CUDA_GLOBAL void kNormalizeWeights(float* grid_mass,   // input
                                   float* grid_vel) {  // output
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < device_settings.num_mpm_nodes) {
        float n_mass = grid_mass[i];
        if (n_mass > FLT_EPSILON) {
            grid_vel[i * 3 + 0] /= n_mass;
            grid_vel[i * 3 + 1] /= n_mass;
            grid_vel[i * 3 + 2] /= n_mass;
        }
    }
}
//////========================================================================================================================================================================
////
CUDA_GLOBAL void kComputeParticleVolumes(const float* sorted_pos,  // input
                                         float* grid_mass,         // output
                                         float* volume) {
    const int p = blockIdx.x * blockDim.x + threadIdx.x;
    if (p < device_settings.num_mpm_markers) {
        const float xix = sorted_pos[p * 3 + 0];
        const float xiy = sorted_pos[p * 3 + 1];
        const float xiz = sorted_pos[p * 3 + 2];
        float particle_density = 0;
        int cx, cy, cz;
        const float bin_edge = device_settings.bin_edge;
        const float inv_bin_edge = device_settings.inv_bin_edge;
        LOOP_TWO_RING_GPUSP(  //
            float weight = N((xix - current_node_locationx) * inv_bin_edge) *
                           N((xiy - current_node_locationy) * inv_bin_edge) *
                           N((xiz - current_node_locationz) * inv_bin_edge);

            particle_density += grid_mass[current_node] * weight;  //
            )
        // Inverse density to remove division
        particle_density = (bin_edge * bin_edge * bin_edge) / particle_density;
        volume[p] = device_settings.mass * particle_density;
    }
}
CUDA_GLOBAL void kFeHat(const float* sorted_pos,  // input
                        const Mat33f* marker_Fe,  // input
                        const float* grid_vel,    // input
                        Mat33f* marker_Fe_hat) {  // output

    const int p = blockIdx.x * blockDim.x + threadIdx.x;
    if (p < device_settings.num_mpm_markers) {
        const float xix = sorted_pos[p * 3 + 0];
        const float xiy = sorted_pos[p * 3 + 1];
        const float xiz = sorted_pos[p * 3 + 2];
        Mat33f Fe_hat_t(0.0);

        int cx, cy, cz;
        const float bin_edge = device_settings.bin_edge;
        const float inv_bin_edge = device_settings.inv_bin_edge;

        LOOP_TWO_RING_GPUSP(

            float vnx = grid_vel[current_node * 3 + 0];  //
            float vny = grid_vel[current_node * 3 + 1];  //
            float vnz = grid_vel[current_node * 3 + 2];

            float Tx = (xix - current_node_locationx) * inv_bin_edge;  //
            float Ty = (xiy - current_node_locationy) * inv_bin_edge;  //
            float Tz = (xiz - current_node_locationz) * inv_bin_edge;  //

            float valx = dN(Tx) * inv_bin_edge * N(Ty) * N(Tz);  //
            float valy = N(Tx) * dN(Ty) * inv_bin_edge * N(Tz);  //
            float valz = N(Tx) * N(Ty) * dN(Tz) * inv_bin_edge;  //

            Fe_hat_t[0] += vnx * valx; Fe_hat_t[1] += vny * valx; Fe_hat_t[2] += vnz * valx;  //
            Fe_hat_t[3] += vnx * valy; Fe_hat_t[4] += vny * valy; Fe_hat_t[5] += vnz * valy;  //
            Fe_hat_t[6] += vnx * valz; Fe_hat_t[7] += vny * valz; Fe_hat_t[8] += vnz * valz;

            //            float3 vel(grid_vel[current_node * 3 + 0], grid_vel[current_node * 3 + 1],
            //                      grid_vel[current_node * 3 + 2]);                  //
            //            float3 kern = dN(xi - current_node_location, inv_bin_edge);  //
            //            Fe_hat_t += OuterProduct(device_settings.dt * vel, kern);

            )

        marker_Fe_hat[p] = (Mat33f(1.0) + device_settings.dt * Fe_hat_t) * marker_Fe[p];
    }
}

// CUDA_GLOBAL void kSVD(Mat33f* marker_Fe_hat, Mat33f* PolarR, Mat33f* PolarS) {
//    const int p = blockIdx.x * blockDim.x + threadIdx.x;
//    if (p < device_settings.num_mpm_markers) {
//        Mat33f U, V, R, S, W;
//        float3 E;
//        SVD(marker_Fe_hat[p], U, E, V);
//        // Perform polar decomposition F = R*S
//        R = MultTranspose(U, V);
//        S = V * MultTranspose(Mat33f(E), V);
//
//        PolarR[p] = R;
//        PolarS[p] = S;
//    }
//}

CUDA_GLOBAL void kApplyForces(const float* sorted_pos,      // input
                              const Mat33f* marker_Fe_hat,  // input
                              const Mat33f* marker_Fe,      // input
                              const Mat33f* marker_Fp,      // input
                              const float* marker_volume,   // input
                              const float* node_mass,       // input
                              const float* plasticity,      // input
                              Mat33f* PolarR,               // input
                              Mat33f* PolarS,               // input
                              float* grid_vel) {
    const int p = blockIdx.x * blockDim.x + threadIdx.x;
    if (p < device_settings.num_mpm_markers) {
        const float xix = sorted_pos[p * 3 + 0];
        const float xiy = sorted_pos[p * 3 + 1];
        const float xiz = sorted_pos[p * 3 + 2];
        Mat33f FE = marker_Fe[p];
        Mat33f FE_hat = marker_Fe_hat[p];

#if 1
        float a = -1.0 / 3.0;
        float Ja = powf(Determinant(FE_hat), a);

        float current_mu = device_settings.mu * expf(device_settings.hardening_coefficient * (plasticity[p]));

        Mat33f A = Potential_Energy_Derivative_Deviatoric(Ja * FE_hat, current_mu, PolarR[p], PolarS[p]);

        Mat33f vPEDFepT =
            device_settings.dt * marker_volume[p] * Z__B(A, FE_hat, Ja, a, InverseTranspose(FE_hat)) * Transpose(FE);
#else
        Mat33f vPEDFepT =
            device_settings.dt * marker_volume[p] *
            Potential_Energy_Derivative_Deviatoric(FE_hat, FP, device_settings.mu,
                                                   device_settings.hardening_coefficient, PolarR[p], PolarS[p]) *
            Transpose(FE);
#endif

        int cx, cy, cz;
        const float bin_edge = device_settings.bin_edge;
        const float inv_bin_edge = device_settings.inv_bin_edge;

        LOOP_TWO_RING_GPUSP(  //

            float Tx = (xix - current_node_locationx) * inv_bin_edge;  //
            float Ty = (xiy - current_node_locationy) * inv_bin_edge;  //
            float Tz = (xiz - current_node_locationz) * inv_bin_edge;  //

            float valx = dN(Tx) * inv_bin_edge * N(Ty) * N(Tz);  //
            float valy = N(Tx) * dN(Ty) * inv_bin_edge * N(Tz);  //
            float valz = N(Tx) * N(Ty) * dN(Tz) * inv_bin_edge;  //

            float fx = vPEDFepT[0] * valx + vPEDFepT[3] * valy + vPEDFepT[6] * valz;
            float fy = vPEDFepT[1] * valx + vPEDFepT[4] * valy + vPEDFepT[7] * valz;
            float fz = vPEDFepT[2] * valx + vPEDFepT[5] * valy + vPEDFepT[8] * valz;

            float mass = node_mass[current_node];  //
            if (mass > 0) {
                atomicAdd(&grid_vel[current_node * 3 + 0], -fx / mass);  //
                atomicAdd(&grid_vel[current_node * 3 + 1], -fy / mass);  //
                atomicAdd(&grid_vel[current_node * 3 + 2], -fz / mass);  //
            })
    }
}
CUDA_GLOBAL void kRhs(const float* node_mass,  // input
                      const float* grid_vel,
                      float* rhs) {
    const int current_node = blockIdx.x * blockDim.x + threadIdx.x;
    if (current_node < device_settings.num_mpm_nodes) {
        float mass = node_mass[current_node];  //
        if (mass > 0) {
            rhs[current_node * 3 + 0] = mass * grid_vel[current_node * 3 + 0];  //
            rhs[current_node * 3 + 1] = mass * grid_vel[current_node * 3 + 1];  //
            rhs[current_node * 3 + 2] = mass * grid_vel[current_node * 3 + 2];  //
        } else {
            rhs[current_node * 3 + 0] = 0;
            rhs[current_node * 3 + 1] = 0;
            rhs[current_node * 3 + 2] = 0;
        }
    }
}

CUDA_GLOBAL void kMultiplyA(const float* sorted_pos,  // input
                            const float* v_array,
                            const float* old_vel_node_mpm,
                            const Mat33f* PolarR,         // input
                            const Mat33f* PolarS,         // input
                            const Mat33f* marker_Fe,      // input
                            const Mat33f* marker_Fp,      // input
                            const Mat33f* marker_Fe_hat,  // input
                            const float* marker_volume,   // input
                            const float* plasticity,      // input
                            float* result_array) {
    const int p = blockIdx.x * blockDim.x + threadIdx.x;
    if (p < device_settings.num_mpm_markers) {
        const float xix = sorted_pos[p * 3 + 0];
        const float xiy = sorted_pos[p * 3 + 1];
        const float xiz = sorted_pos[p * 3 + 2];
        // float VAP[7];
        // float delta_F[7] = {0, 0, 0, 0, 0, 0, 0, 0, 0};
        Mat33f delta_F(0);
        int cx, cy, cz;
        const float bin_edge = device_settings.bin_edge;
        const float inv_bin_edge = device_settings.inv_bin_edge;

        LOOP_TWO_RING_GPUSP(  //

            float vnx = v_array[current_node * 3 + 0];  //
            float vny = v_array[current_node * 3 + 1];  //
            float vnz = v_array[current_node * 3 + 2];

            float Tx = (xix - current_node_locationx) * inv_bin_edge;  //
            float Ty = (xiy - current_node_locationy) * inv_bin_edge;  //
            float Tz = (xiz - current_node_locationz) * inv_bin_edge;  //

            float valx = dN(Tx) * inv_bin_edge * N(Ty) * N(Tz);  //
            float valy = N(Tx) * dN(Ty) * inv_bin_edge * N(Tz);  //
            float valz = N(Tx) * N(Ty) * dN(Tz) * inv_bin_edge;  //

            delta_F[0] += vnx * valx; delta_F[1] += vny * valx; delta_F[2] += vnz * valx;  //
            delta_F[3] += vnx * valy; delta_F[4] += vny * valy; delta_F[5] += vnz * valy;  //
            delta_F[6] += vnx * valz; delta_F[7] += vny * valz; delta_F[8] += vnz * valz;)

        Mat33f m_FE = marker_Fe[p];
        delta_F = delta_F * m_FE;

        float current_mu = device_settings.mu * expf(device_settings.hardening_coefficient * (plasticity[p]));
        Mat33f RE = PolarR[p];
        Mat33f SE = PolarS[p];
        Mat33f F = marker_Fe_hat[p];
        float a = -one_third;
        float Ja = powf(Determinant(F), a);
        Mat33f H = InverseTranspose(F);
        Mat33f FE = Ja * F;

        Mat33f B_Z = B__Z(delta_F, F, Ja, a, H);
        Mat33f WE = TransposeMult(RE, B_Z);
        // C is the original second derivative
        Mat33f C_B_Z = 2 * current_mu * (B_Z - Solve_dR(RE, SE, WE));

        Mat33f A = float(2.) * current_mu * (FE - RE);
        Mat33f VAP = marker_volume[p] *
                     MultTranspose(Z__B(C_B_Z, F, Ja, a, H) + a * DoubleDot(H, delta_F) * Z__B(A, F, Ja, a, H) +
                                       a * Ja * DoubleDot(A, delta_F) * H +
                                       -a * Ja * DoubleDot(A, F) * H * TransposeMult(delta_F, H),
                                   m_FE);

        // Mat33f VAP = d2PsidFdFO(delta_F, m_FE_hat, PolarR[p], PolarS[p], current_mu);

        // WeakEqual(VAP, VAP2);

        LOOP_TWO_RING_GPUSP(                                           //
            float Tx = (xix - current_node_locationx) * inv_bin_edge;  //
            float Ty = (xiy - current_node_locationy) * inv_bin_edge;  //
            float Tz = (xiz - current_node_locationz) * inv_bin_edge;  //

            float valx = dN(Tx) * inv_bin_edge * N(Ty) * N(Tz);  //
            float valy = N(Tx) * dN(Ty) * inv_bin_edge * N(Tz);  //
            float valz = N(Tx) * N(Ty) * dN(Tz) * inv_bin_edge;  //

            float resx = VAP[0] * valx + VAP[3] * valy + VAP[6] * valz;
            float resy = VAP[1] * valx + VAP[4] * valy + VAP[7] * valz;
            float resz = VAP[2] * valx + VAP[5] * valy + VAP[8] * valz;

            atomicAdd(&result_array[current_node * 3 + 0], resx); atomicAdd(&result_array[current_node * 3 + 1], resy);
            atomicAdd(&result_array[current_node * 3 + 2], resz););
    }
}
CUDA_GLOBAL void kMultiplyB(const float* v_array,
                            const float* old_vel_node_mpm,
                            const float* node_mass,
                            float* result_array) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < device_settings.num_mpm_nodes) {
        float mass = node_mass[i];
        if (mass > 0) {
            result_array[i * 3 + 0] += mass * (v_array[i * 3 + 0]);
            result_array[i * 3 + 1] += mass * (v_array[i * 3 + 1]);
            result_array[i * 3 + 2] += mass * (v_array[i * 3 + 2]);
        }
    }
}

void MPM_ComputeBounds() {
    max_bounding_point = make_float3(-FLT_MAX, -FLT_MAX, -FLT_MAX);
    min_bounding_point = make_float3(FLT_MAX, FLT_MAX, FLT_MAX);

    cudaMemcpyAsync(lower_bound, &min_bounding_point, sizeof(float3), cudaMemcpyHostToDevice);
    cudaMemcpyAsync(upper_bound, &max_bounding_point, sizeof(float3), cudaMemcpyHostToDevice);

    kComputeBounds<<<CONFIG(host_settings.num_mpm_markers)>>>(pos.data_d,    //
                                                              lower_bound,   //
                                                              upper_bound);  //

    cudaMemcpy(&min_bounding_point, lower_bound, sizeof(float3), cudaMemcpyDeviceToHost);
    cudaMemcpy(&max_bounding_point, upper_bound, sizeof(float3), cudaMemcpyDeviceToHost);

    min_bounding_point.x = host_settings.kernel_radius * roundf(min_bounding_point.x / host_settings.kernel_radius);
    min_bounding_point.y = host_settings.kernel_radius * roundf(min_bounding_point.y / host_settings.kernel_radius);
    min_bounding_point.z = host_settings.kernel_radius * roundf(min_bounding_point.z / host_settings.kernel_radius);

    max_bounding_point.x = host_settings.kernel_radius * roundf(max_bounding_point.x / host_settings.kernel_radius);
    max_bounding_point.y = host_settings.kernel_radius * roundf(max_bounding_point.y / host_settings.kernel_radius);
    max_bounding_point.z = host_settings.kernel_radius * roundf(max_bounding_point.z / host_settings.kernel_radius);

    max_bounding_point = max_bounding_point + host_settings.kernel_radius * 8;
    min_bounding_point = min_bounding_point - host_settings.kernel_radius * 6;

    cudaMemcpyToSymbolAsync(system_bounds, &min_bounding_point, sizeof(float3), 0, cudaMemcpyHostToDevice);
    cudaMemcpyToSymbolAsync(system_bounds, &max_bounding_point, sizeof(float3), sizeof(float3), cudaMemcpyHostToDevice);

    host_settings.bin_edge = host_settings.kernel_radius * 2;

    host_settings.bins_per_axis_x = (max_bounding_point.x - min_bounding_point.x) / host_settings.bin_edge;
    host_settings.bins_per_axis_y = (max_bounding_point.y - min_bounding_point.y) / host_settings.bin_edge;
    host_settings.bins_per_axis_z = (max_bounding_point.z - min_bounding_point.z) / host_settings.bin_edge;

    host_settings.inv_bin_edge = float(1.) / host_settings.bin_edge;
    host_settings.num_mpm_nodes =
        host_settings.bins_per_axis_x * host_settings.bins_per_axis_y * host_settings.bins_per_axis_z;

    cudaCheck(cudaMemcpyToSymbolAsync(device_settings, &host_settings, sizeof(MPM_Settings)));

    printf("max_bounding_point [%f %f %f]\n", max_bounding_point.x, max_bounding_point.y, max_bounding_point.z);
    printf("min_bounding_point [%f %f %f]\n", min_bounding_point.x, min_bounding_point.y, min_bounding_point.z);
    printf("Compute DOF [%d %d %d] [%f] %d %d\n", host_settings.bins_per_axis_x, host_settings.bins_per_axis_y,
           host_settings.bins_per_axis_z, host_settings.bin_edge, host_settings.num_mpm_nodes,
           host_settings.num_mpm_markers);
}
//

void Multiply(gpu_vector<float>& input, gpu_vector<float>& output) {
    int size = input.size();

    kMultiplyA<<<CONFIG(size)>>>(pos.data_d,    // input
                                 input.data_d,  //
                                 old_vel_node_mpm.data_d,
                                 PolarR.data_d,             // input
                                 PolarS.data_d,             // input
                                 marker_Fe.data_d,          // input
                                 marker_Fp.data_d,          // input
                                 marker_Fe_hat.data_d,      // input
                                 marker_volume.data_d,      // input
                                 marker_plasticity.data_d,  // input
                                 output.data_d);

    kMultiplyB<<<CONFIG(size)>>>(input.data_d, old_vel_node_mpm.data_d, node_mass.data_d, output.data_d);
}

CUDA_GLOBAL void kSubtract(int size, float* x, float* y) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < size) {
        y[i] = y[i] - x[i];
    }
}

template <bool inner>
CUDA_GLOBAL void kResetGlobals() {
    if (inner) {
        dot_ms_ms = 0;
        dot_ms_my = 0;
        dot_my_my = 0;
    } else {
        alpha = 0.0001;
    }
}

template <bool even>
CUDA_GLOBAL void kUpdateAlpha(int num_items, float* ml_p, float* ml, float* mg_p, float* mg) {
    typedef cub::BlockReduce<float, num_threads_per_block> BlockReduce;
    __shared__ typename BlockReduce::TempStorage temp_storage;
    const int block_start = blockDim.x * blockIdx.x;
    const int num_valid = min(num_items - block_start, blockDim.x);

    const int tid = block_start + threadIdx.x;
    if (tid < num_items) {
        float data, block_sum;
        float ms = ml_p[tid] - ml[tid];
        float my = mg_p[tid] - mg[tid];

        if (even) {
            data = ms * ms;
            block_sum = BlockReduce(temp_storage).Reduce(data, cub::Sum(), num_valid);
            if (threadIdx.x == 0) {
                atomicAdd(&dot_ms_ms, block_sum);
            }
        } else {
            data = my * my;
            block_sum = BlockReduce(temp_storage).Reduce(data, cub::Sum(), num_valid);
            if (threadIdx.x == 0) {
                atomicAdd(&dot_my_my, block_sum);
            }
        }
        __syncthreads();
        data = ms * my;
        block_sum = BlockReduce(temp_storage).Reduce(data, cub::Sum(), num_valid);

        if (threadIdx.x == 0) {
            atomicAdd(&dot_ms_my, block_sum);
        }
    }
}

template <bool even>
CUDA_GLOBAL void kAlpha() {
    if (even) {
        if (dot_ms_my <= 0) {
            alpha = neg_BB1_fallback;
        } else {
            alpha = fminf(a_max, fmaxf(a_min, dot_ms_ms / dot_ms_my));
        }
    } else {
        if (dot_ms_my <= 0) {
            alpha = neg_BB2_fallback;
        } else {
            alpha = fminf(a_max, fmaxf(a_min, dot_ms_my / dot_my_my));
        }
    }
    // printf("alpha: %f %f %f %f \n", alpha, dot_ms_ms, dot_ms_my, dot_my_my);
}

CUDA_GLOBAL void kCompute_ml_p(int num_items, float* ml, float* mg, float* ml_p) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < num_items) {
        ml_p[i] = ml[i] - alpha * mg[i];
        // printf("mlps : [%f %f %f]\n", ml_p[i], ml[i], mg[i]);
    }
}
CUDA_GLOBAL void kResidual(int num_items, float* mg, float* dot_g_proj_norm) {
    typedef cub::BlockReduce<float, num_threads_per_block> BlockReduce;
    __shared__ typename BlockReduce::TempStorage temp_storage;
    const int block_start = blockDim.x * blockIdx.x;
    const int num_valid = min(num_items - block_start, blockDim.x);
    float data, block_sum;
    const int tid = block_start + threadIdx.x;
    if (tid < num_items) {
        data = mg[tid] * mg[tid];

        block_sum = BlockReduce(temp_storage).Reduce(data, cub::Sum(), num_valid);

        if (threadIdx.x == 0) {
            atomicAdd(&dot_g_proj_norm[0], block_sum);
        }
        // printf("resid [%f %f]\n", mg[tid], dot_g_proj_norm[0]);
    }
}

float time_no_shur = 0;
float time_shur = 0;
void MPM_BBSolver(gpu_vector<float>& r, gpu_vector<float>& delta_v) {
    time_shur = 0;
    time_no_shur = 0;
    const uint size = r.size();
    float lastgoodres = 10e30;
    {
        CudaEventTimer timer(start, stop, true, time_no_shur);

        dot_g_proj_norm.resize(1);
        ml.resize(size);
        mg.resize(size);
        mg_p.resize(size);
        ml_p.resize(size);
        ml = delta_v;
        mg = 0;
    }
    {
        CudaEventTimer timer(start, stop, true, time_shur);
        Multiply(ml, mg);
    }
    {
        CudaEventTimer timer(start, stop, true, time_no_shur);
        kSubtract<<<CONFIG(size)>>>(size, r.data_d, mg.data_d);
        mg_p = mg;
    }

    kResetGlobals<false><<<1, 1>>>();

    for (int current_iteration = 0; current_iteration < host_settings.num_iterations; current_iteration++) {
        {
            CudaEventTimer timer(start, stop, true, time_no_shur);
            kResetGlobals<true><<<1, 1>>>();
            kCompute_ml_p<<<CONFIG(size)>>>(size, ml.data_d, mg.data_d, ml_p.data_d);
            mg_p = 0;
        }
        {
            CudaEventTimer timer(start, stop, true, time_shur);
            Multiply(ml_p, mg_p);
        }
        {
            CudaEventTimer timer(start, stop, true, time_no_shur);
            kSubtract<<<CONFIG(size)>>>(size, r.data_d, mg_p.data_d);

            if (current_iteration % 2 == 0) {
                kUpdateAlpha<true><<<CONFIG(size)>>>(size, ml_p.data_d, ml.data_d, mg_p.data_d, mg.data_d);
                kAlpha<true><<<1, 1>>>();
            } else {
                kUpdateAlpha<false><<<CONFIG(size)>>>(size, ml_p.data_d, ml.data_d, mg_p.data_d, mg.data_d);
                kAlpha<false><<<1, 1>>>();
            }

            ml = ml_p;
            mg = mg_p;

            dot_g_proj_norm = 0;
            kResidual<<<CONFIG(size)>>>(size, mg.data_d, dot_g_proj_norm.data_d);
            dot_g_proj_norm.copyDeviceToHost();
            float g_proj_norm = sqrtf(dot_g_proj_norm.data_h[0]);

            if (g_proj_norm < lastgoodres) {
                lastgoodres = g_proj_norm;
                delta_v = ml;
            }
            //            printf("[%f]\n", lastgoodres);
        }
    }
    cudaCheck(cudaPeekAtLastError());
    cudaCheck(cudaDeviceSynchronize());
    printf("MPM Solver: [%f, %f %f] \n", time_no_shur, time_shur, lastgoodres);
}
CUDA_GLOBAL void kIncrementVelocity(float* delta_v, float* old_vel_node_mpm, float* grid_vel) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < device_settings.num_mpm_nodes) {
        grid_vel[i * 3 + 0] += delta_v[i * 3 + 0] - old_vel_node_mpm[i * 3 + 0];
        grid_vel[i * 3 + 1] += delta_v[i * 3 + 1] - old_vel_node_mpm[i * 3 + 1];
        grid_vel[i * 3 + 2] += delta_v[i * 3 + 2] - old_vel_node_mpm[i * 3 + 2];
    }
}

CUDA_GLOBAL void kUpdateParticleVelocity(float* grid_vel,
                                         float* old_vel_node_mpm,
                                         float* pos_marker,
                                         float* vel_marker,
                                         Mat33f* marker_Fe,
                                         Mat33f* marker_Fp) {
    const int p = blockIdx.x * blockDim.x + threadIdx.x;
    if (p < device_settings.num_mpm_markers) {
        const float xix = pos_marker[p * 3 + 0];
        const float xiy = pos_marker[p * 3 + 1];
        const float xiz = pos_marker[p * 3 + 2];
        float3 V_flip;
        V_flip.x = vel_marker[p * 3 + 0];
        V_flip.y = vel_marker[p * 3 + 1];
        V_flip.z = vel_marker[p * 3 + 2];
        float3 V_pic = make_float3(0.0, 0.0, 0.0);

        const float bin_edge = device_settings.bin_edge;
        const float inv_bin_edge = device_settings.inv_bin_edge;
        int cx, cy, cz;

        LOOP_TWO_RING_GPUSP(

            float weight = N((xix - current_node_locationx) * inv_bin_edge) *
                           N((xiy - current_node_locationy) * inv_bin_edge) *
                           N((xiz - current_node_locationz) * inv_bin_edge);

            float vnx = grid_vel[current_node * 3 + 0];  //
            float vny = grid_vel[current_node * 3 + 1];  //
            float vnz = grid_vel[current_node * 3 + 2];

            V_pic.x += vnx * weight;                                              //
            V_pic.y += vny * weight;                                              //
            V_pic.z += vnz * weight;                                              //
            V_flip.x += (vnx - old_vel_node_mpm[current_node * 3 + 0]) * weight;  //
            V_flip.y += (vny - old_vel_node_mpm[current_node * 3 + 1]) * weight;  //
            V_flip.z += (vnz - old_vel_node_mpm[current_node * 3 + 2]) * weight;  //
            )
        float3 new_vel = (1.0 - alpha) * V_pic + alpha * V_flip;

        float speed = Length(new_vel);
        if (speed > device_settings.max_velocity) {
            new_vel = new_vel * device_settings.max_velocity / speed;
        }
        vel_marker[p * 3 + 0] = new_vel.x;
        vel_marker[p * 3 + 1] = new_vel.y;
        vel_marker[p * 3 + 2] = new_vel.z;
    }
}
CUDA_GLOBAL void kUpdateDeformationGradient(float* grid_vel,
                                            float* pos_marker,
                                            Mat33f* marker_Fe,
                                            Mat33f* marker_Fp,
                                            Mat33f* marker_RE,
                                            float* plasticity,
                                            float* JE_JP) {
    const int p = blockIdx.x * blockDim.x + threadIdx.x;
    if (p < device_settings.num_mpm_markers) {
        const float xix = pos_marker[p * 3 + 0];
        const float xiy = pos_marker[p * 3 + 1];
        const float xiz = pos_marker[p * 3 + 2];
        Mat33f vel_grad(0.0);

        int cx, cy, cz;
        const float bin_edge = device_settings.bin_edge;
        const float inv_bin_edge = device_settings.inv_bin_edge;

        LOOP_TWO_RING_GPUSP(float vnx = grid_vel[current_node * 3 + 0];  //
                            float vny = grid_vel[current_node * 3 + 1];  //
                            float vnz = grid_vel[current_node * 3 + 2];

                            float Tx = (xix - current_node_locationx) * inv_bin_edge;  //
                            float Ty = (xiy - current_node_locationy) * inv_bin_edge;  //
                            float Tz = (xiz - current_node_locationz) * inv_bin_edge;  //

                            float valx = dN(Tx) * inv_bin_edge * N(Ty) * N(Tz);  //
                            float valy = N(Tx) * dN(Ty) * inv_bin_edge * N(Tz);  //
                            float valz = N(Tx) * N(Ty) * dN(Tz) * inv_bin_edge;  //

                            vel_grad[0] += vnx * valx; vel_grad[1] += vny * valx; vel_grad[2] += vnz * valx;  //
                            vel_grad[3] += vnx * valy; vel_grad[4] += vny * valy; vel_grad[5] += vnz * valy;  //
                            vel_grad[6] += vnx * valz; vel_grad[7] += vny * valz; vel_grad[8] += vnz * valz;

                            )
        Mat33f delta_F = (Mat33f(1.0) + device_settings.dt * vel_grad);
        Mat33f Fe_tmp = delta_F * marker_Fe[p];
        Mat33f F_tmp = Fe_tmp * marker_Fp[p];
        Mat33f U, V;
        float3 E;
        SVD(Fe_tmp, U, E, V);
        float3 E_clamped = E;
#if 1

#if 0
        // Simple box clamp
        E_clamped.x = Clamp(E.x, 1.0 - device_settings.theta_c, 1.0 + device_settings.theta_s);
        E_clamped.y = Clamp(E.y, 1.0 - device_settings.theta_c, 1.0 + device_settings.theta_s);
        E_clamped.z = Clamp(E.z, 1.0 - device_settings.theta_c, 1.0 + device_settings.theta_s);
#else
        // Clamp to sphere (better)
        float center = 1.0 + (device_settings.theta_s - device_settings.theta_c) * .5;
        float radius = (device_settings.theta_s + device_settings.theta_c) * .5;
        float3 offset = E - center;
        float lent = Length(offset);
        if (lent > radius) {
            offset = offset * radius / lent;
        }
        E_clamped = offset + center;

#endif

        plasticity[p] = fabsf(E.x * E.y * E.z - E_clamped.x * E_clamped.y * E_clamped.z);
// printf("E %d %f %f  %f\n", p, E_clamped.x * E_clamped.y * E_clamped.z, E.x * E.y * E.z, plasticity[p]);
#else
        float flow = Abs(Determinant(delta_F));

        Mat33f P = 2 * device_settings.mu * Mat33f((E - 1));
        //+ device_settings.lambda * Trace(Mat33f((E - 1))) * Mat33f(1.0);
        float norm_P = Norm(P);
        if (norm_P > device_settings.yield_stress) {
            float gam = Min(Max(flow * (norm_P - device_settings.yield_stress
                                        // -total_flow[p] * device_settings.hardening_coefficient
                                        ) /
                                    norm_P,
                                0),
                            1.0);
            E_clamped = float3(powf(E.x, gam), powf(E.y, gam), powf(E.z, gam));
            float current_lambda =
                device_settings.lambda * Exp(device_settings.hardening_coefficient * (float(1.0) - total_flow[p]));
            // device_settings.lambda * (1 + device_settings.poissons_ratio) *
            //(1 - 2 * device_settings.poissons_ratio) / device_settings.poissons_ratio;
            printf("Stress: %f %f %f %f\n", norm_P, cohesion[p], total_flow[p], Determinant(Mat33f(E_clamped)));

            total_flow[p] += Norm(P);
            // How to compute new stiffness?
        } else {
            E_clamped = E;
            // printf("Stress: %f %f\n", norm_P, flow);
        }

#endif

        // Inverse of Diagonal E_clamped matrix is 1/E_clamped
        Mat33f m_FP = V * MultTranspose(Mat33f(1.0 / E_clamped), U) * F_tmp;
        float JP_new = Determinant(m_FP);
        // Ensure that F_p is purely deviatoric

        Mat33f T1 = powf(JP_new, 1.0 / 3.0) * U * MultTranspose(Mat33f(E_clamped), V);
        Mat33f T2 = powf(JP_new, -1.0 / 3.0) * m_FP;

        JE_JP[p * 2 + 0] = Determinant(T1);
        JE_JP[p * 2 + 1] = Determinant(T2);

        marker_Fe[p] = T1;
        marker_Fp[p] = T2;

        // printf("JP: %f JE: %f\n", Determinant(marker_Fe[p]), Determinant(marker_Fp[p]));
    }
}
void MPM_UpdateDeformationGradient(MPM_Settings& settings,
                                   std::vector<float>& positions,
                                   std::vector<float>& velocities,
                                   std::vector<float>& jejp) {
    cudaEventCreate(&start);
    cudaEventCreate(&stop);

    host_settings = settings;
    printf("Solving MPM: %d\n", host_settings.num_iterations);

    pos.data_h = positions;

    pos.copyHostToDevice();

    vel.data_h = velocities;

    vel.copyHostToDevice();

    cudaCheck(cudaMemcpyToSymbolAsync(device_settings, &host_settings, sizeof(MPM_Settings)));

    MPM_ComputeBounds();

    node_mass.resize(host_settings.num_mpm_nodes);
    node_mass = 0;

    grid_vel.resize(host_settings.num_mpm_nodes * 3);
    grid_vel = 0;
    {
        CudaEventTimer timer(start, stop, true, time_measured);
        // ========================================================================================
        kRasterize<<<CONFIG(host_settings.num_mpm_markers)>>>(pos.data_d,        // input
                                                              vel.data_d,        // input
                                                              node_mass.data_d,  // output
                                                              grid_vel.data_d    // output
                                                              );
    }
    printf("kRasterize: %f\n", time_measured);
    time_measured = 0;
    {
        CudaEventTimer timer(start, stop, true, time_measured);
        kNormalizeWeights<<<CONFIG(host_settings.num_mpm_nodes)>>>(node_mass.data_d,  // output
                                                                   grid_vel.data_d);
    }

    printf("kNormalizeWeights: %f\n", time_measured);
    time_measured = 0;
    {
        CudaEventTimer timer(start, stop, true, time_measured);
        kUpdateDeformationGradient<<<CONFIG(host_settings.num_mpm_markers)>>>(
            grid_vel.data_d, pos.data_d, marker_Fe.data_d, marker_Fp.data_d, PolarR.data_d, marker_plasticity.data_d,
            JE_JP.data_d);
        JE_JP.copyDeviceToHost();
    }
    jejp = JE_JP.data_h;
    printf("kUpdateDeformationGradient: %f\n", time_measured);
    time_measured = 0;
}
void MPM_Solve(MPM_Settings& settings,
               std::vector<float>& positions,
               std::vector<float>& velocities) {
    old_vel_node_mpm.resize(host_settings.num_mpm_nodes * 3);
    rhs.resize(host_settings.num_mpm_nodes * 3);
    old_vel_node_mpm = grid_vel;

    //    cudaCheck(cudaPeekAtLastError());
    //    cudaCheck(cudaDeviceSynchronize());
    {
        CudaEventTimer timer(start, stop, true, time_measured);
        kFeHat<<<CONFIG(host_settings.num_mpm_markers)>>>(pos.data_d, marker_Fe.data_d, grid_vel.data_d,
                                                          marker_Fe_hat.data_d);
    }
    printf("kFeHat: %f\n", time_measured);
    time_measured = 0;
    // kSVD<<<CONFIG(host_settings.num_mpm_markers)>>>(marker_Fe_hat.data_d, PolarR.data_d, PolarS.data_d);
    {
        CudaEventTimer timer(start, stop, true, time_measured);
        kApplyForces<<<CONFIG(host_settings.num_mpm_markers)>>>(pos.data_d,                // input
                                                                marker_Fe_hat.data_d,      // input
                                                                marker_Fe.data_d,          // input
                                                                marker_Fp.data_d,          // input
                                                                marker_volume.data_d,      // input
                                                                node_mass.data_d,          // input
                                                                marker_plasticity.data_d,  // input
                                                                PolarR.data_d,             // output
                                                                PolarS.data_d,             // output
                                                                grid_vel.data_d);          // output
    }
    printf("kApplyForces: %f\n", time_measured);
    time_measured = 0;

    {
        CudaEventTimer timer(start, stop, true, time_measured);
        kRhs<<<CONFIG(host_settings.num_mpm_nodes)>>>(node_mass.data_d, grid_vel.data_d, rhs.data_d);
    }
    printf("kRhs: %f\n", time_measured);
    time_measured = 0;

    delta_v.resize(host_settings.num_mpm_nodes * 3);
    delta_v = old_vel_node_mpm;

    MPM_BBSolver(rhs, delta_v);
    {
        CudaEventTimer timer(start, stop, true, time_measured);
        kIncrementVelocity<<<CONFIG(host_settings.num_mpm_nodes)>>>(delta_v.data_d, old_vel_node_mpm.data_d,
                                                                    grid_vel.data_d);
    }
    printf("kIncrementVelocity: %f\n", time_measured);
    time_measured = 0;
    {
        CudaEventTimer timer(start, stop, true, time_measured);
        kUpdateParticleVelocity<<<CONFIG(host_settings.num_mpm_markers)>>>(
            grid_vel.data_d, old_vel_node_mpm.data_d, pos.data_d, vel.data_d, marker_Fe.data_d, marker_Fp.data_d);
    }
    printf("kUpdateParticleVelocity: %f\n", time_measured);
    time_measured = 0;

    vel.copyDeviceToHost();
    velocities = vel.data_h;

    cudaEventDestroy(start);
    cudaEventDestroy(stop);
}

CUDA_GLOBAL void kInitFeFp(Mat33f* marker_Fe, Mat33f* marker_Fp, Mat33f* marker_RE, Mat33f* marker_SE) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < device_settings.num_mpm_markers) {
        marker_Fe[i] = Mat33f(1);
        marker_Fp[i] = Mat33f(1);
        marker_RE[i] = Mat33f(1);
        marker_SE[i] = Mat33f(1);
    }
}

void MPM_Initialize(MPM_Settings& settings, std::vector<float>& positions) {
    cudaEventCreate(&start);
    cudaEventCreate(&stop);

    host_settings = settings;

    cudaCheck(cudaMalloc(&lower_bound, sizeof(float3)));
    cudaCheck(cudaMalloc(&upper_bound, sizeof(float3)));

    pos.data_h = positions;

    pos.copyHostToDevice();

    cudaCheck(cudaMemcpyToSymbolAsync(device_settings, &host_settings, sizeof(MPM_Settings)));

    MPM_ComputeBounds();
    marker_volume.resize(host_settings.num_mpm_markers);
    node_mass.resize(host_settings.num_mpm_nodes);
    node_mass = 0;

    {
        CudaEventTimer timer(start, stop, true, time_measured);
        kRasterize<<<CONFIG(host_settings.num_mpm_markers)>>>(pos.data_d,         // input
                                                              node_mass.data_d);  // output
    }
    printf("kRasterize: %f\n", time_measured);
    time_measured = 0;

    {
        CudaEventTimer timer(start, stop, true, time_measured);
        kComputeParticleVolumes<<<CONFIG(host_settings.num_mpm_markers)>>>(pos.data_d,             // input
                                                                           node_mass.data_d,       // input
                                                                           marker_volume.data_d);  // output
    }

    printf("kComputeParticleVolumes: %f\n", time_measured);
    time_measured = 0;
    {
        CudaEventTimer timer(start, stop, true, time_measured);

        marker_Fe.resize(host_settings.num_mpm_markers);
        marker_Fe_hat.resize(host_settings.num_mpm_markers);
        marker_Fp.resize(host_settings.num_mpm_markers);
        marker_delta_F.resize(host_settings.num_mpm_markers);
        PolarR.resize(host_settings.num_mpm_markers);
        PolarS.resize(host_settings.num_mpm_markers);
        JE_JP.resize(host_settings.num_mpm_markers * 2);
        marker_plasticity.resize(host_settings.num_mpm_markers);
        marker_plasticity = 0;
    }
    printf("Resize: %f\n", time_measured);
    time_measured = 0;
    {
        CudaEventTimer timer(start, stop, true, time_measured);
        kInitFeFp<<<CONFIG(host_settings.num_mpm_markers)>>>(marker_Fe.data_d,  // output
                                                             marker_Fp.data_d,  // output
                                                             PolarR.data_d,     // output
                                                             PolarS.data_d);    // output
    }
    printf("kInitFeFp: %f\n", time_measured);
    time_measured = 0;
    //    cudaCheck(cudaPeekAtLastError());
    //    cudaCheck(cudaDeviceSynchronize());

    cudaEventDestroy(start);
    cudaEventDestroy(stop);
}
}