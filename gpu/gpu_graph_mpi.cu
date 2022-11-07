#include <schedule_IEP.h>
#include <dataloader.h>
#include <graph.h>
#include <mpi.h>
#include <omp.h>

#include <unistd.h>
#include <cstdlib>
#include <cassert>
#include <cstdio>
#include <atomic>
#include <tuple>
#include <utility>
#include <string>
#include <chrono>
#include <cmath>

#include "pattern_matching.cuh"

__device__ void gpu_pattern_matching_final_in_exclusion(const GPUSchedule* schedule, GPUVertexSet* vertex_set, GPUVertexSet& subtraction_set,
    GPUVertexSet& tmp_set, unsigned long long& local_ans,  uint32_t *edge, uint32_t *vertex) {
    int last_pos = -1;
    long long val;

    extern __shared__ char ans_array[];
    int* ans = ((int*) (ans_array + schedule->ans_array_offset)) 
        + schedule->in_exclusion_optimize_vertex_id_size * (threadIdx.x / THREADS_PER_WARP);
    
    for (int i = 0; i < schedule->in_exclusion_optimize_vertex_id_size; ++i) {
        if (schedule->in_exclusion_optimize_vertex_flag[i]) {
            ans[i] = vertex_set[schedule->in_exclusion_optimize_vertex_id[i]].get_size() - schedule->in_exclusion_optimize_vertex_coef[i];
        } else {
            ans[i] = unordered_subtraction_size(vertex_set[schedule->in_exclusion_optimize_vertex_id[i]], subtraction_set);
        }
    }

    for (int pos = 0; pos < schedule->in_exclusion_optimize_array_size; ++pos) {
        if (pos == last_pos + 1)
            val = ans[schedule->in_exclusion_optimize_ans_pos[pos]];
        else {
            if (val != 0)
                val = val * ans[schedule->in_exclusion_optimize_ans_pos[pos]];
        }
        if (schedule->in_exclusion_optimize_flag[pos]) {
            last_pos = pos;
            local_ans += val * schedule->in_exclusion_optimize_coef[pos];
        }
    }
}

constexpr int MAX_DEPTH = 5; // 非递归pattern matching支持的最大深度

template <int depth>
__device__ void gpu_pattern_matching_func(const GPUSchedule* schedule, GPUVertexSet* vertex_set, GPUVertexSet& subtraction_set,
    GPUVertexSet& tmp_set, unsigned long long& local_ans, uint32_t *edge, uint32_t *vertex)
{

    if (depth == schedule->get_size() - schedule->get_in_exclusion_optimize_num()) {
        gpu_pattern_matching_final_in_exclusion(schedule, vertex_set, subtraction_set, tmp_set, local_ans,  edge, vertex);
        return;    
    }

    int loop_set_prefix_id = schedule->get_loop_set_prefix_id(depth);
    int loop_size = vertex_set[loop_set_prefix_id].get_size();
    if (loop_size <= 0) //这个判断可能可以删了
        return;

    uint32_t* loop_data_ptr = vertex_set[loop_set_prefix_id].get_data_ptr();
    uint32_t min_vertex = 0xffffffff;
    for (int i = schedule->get_restrict_last(depth); i != -1; i = schedule->get_restrict_next(i))
        if (min_vertex > subtraction_set.get_data(schedule->get_restrict_index(i)))
            min_vertex = subtraction_set.get_data(schedule->get_restrict_index(i));
    for (int i = 0; i < loop_size; ++i) {
        uint32_t v = loop_data_ptr[i];
        if (min_vertex <= v)
            break;
        if (subtraction_set.has_data(v))
            continue;
        unsigned int l, r;
        get_edge_index(v, l, r);
        bool is_zero = false;
        for (int prefix_id = schedule->get_last(depth); prefix_id != -1; prefix_id = schedule->get_next(prefix_id)) {
            vertex_set[prefix_id].build_vertex_set(schedule, vertex_set, &edge[l], r - l, prefix_id);
            if (vertex_set[prefix_id].get_size() == schedule->get_break_size(prefix_id)) {
                is_zero = true;
                break;
            }
        }
        if (is_zero)
            continue;
        if (depth + 1 != MAX_DEPTH) {
            if (threadIdx.x % THREADS_PER_WARP == 0)
                subtraction_set.push_back(v);
            __threadfence_block();
        }
        gpu_pattern_matching_func<depth + 1>(schedule, vertex_set, subtraction_set, tmp_set, local_ans, edge, vertex);
        if (depth + 1 != MAX_DEPTH) {
            if (threadIdx.x % THREADS_PER_WARP == 0)
                subtraction_set.pop_back();
            __threadfence_block();
        }
    }
}

template <>
__device__ void gpu_pattern_matching_func<MAX_DEPTH>(const GPUSchedule* schedule, GPUVertexSet* vertex_set, GPUVertexSet& subtraction_set,
        GPUVertexSet& tmp_set, unsigned long long& local_ans, uint32_t *edge, uint32_t *vertex)
{
    // assert(false);
}

// device global variables
__device__ unsigned long long dev_sum;
__device__ unsigned int dev_cur_task;

__global__ void gpu_pattern_matching(unsigned task_end, size_t buffer_size, uint32_t *edge_from, uint32_t *edge, uint32_t *vertex, uint32_t *tmp, const GPUSchedule* schedule) {
    __shared__ unsigned int block_edge_idx[WARPS_PER_BLOCK];
    extern __shared__ GPUVertexSet block_vertex_set[];
    
    int num_prefixes = schedule->get_total_prefix_num();
    int num_vertex_sets_per_warp = num_prefixes + 2;

    int wid = threadIdx.x / THREADS_PER_WARP; // warp id within the block
    int lid = threadIdx.x % THREADS_PER_WARP; // lane id
    int global_wid = blockIdx.x * WARPS_PER_BLOCK + wid; // global warp id
    unsigned int &edge_idx = block_edge_idx[wid];
    GPUVertexSet *vertex_set = block_vertex_set + wid * num_vertex_sets_per_warp;

    if (lid == 0) {
        edge_idx = 0;
        ptrdiff_t offset = buffer_size * global_wid * num_vertex_sets_per_warp;
        for (int i = 0; i < num_vertex_sets_per_warp; ++i) {
            vertex_set[i].set_data_ptr(tmp + offset); // 注意这是个指针+整数运算，自带*4
            offset += buffer_size;
        }
    }
    GPUVertexSet& subtraction_set = vertex_set[num_prefixes];
    GPUVertexSet& tmp_set = vertex_set[num_prefixes + 1];

    __threadfence_block();

    uint32_t v0, v1;
    uint32_t l, r;

    unsigned long long sum = 0;

    while (true) {
        if (lid == 0) {
            edge_idx = atomicAdd(&dev_cur_task, 1);
            unsigned int i = edge_idx;
            if (i < task_end) {
                subtraction_set.init();
                subtraction_set.push_back(edge_from[i]);
                subtraction_set.push_back(edge[i]);
            }
        }
        __threadfence_block();

        unsigned int i = edge_idx;
        if (i >= task_end) break;
       
        // for edge in E
        v0 = edge_from[i];
        v1 = edge[i];

        //目前只考虑pattern size>2的情况
        //start v1, depth = 1
        if (schedule->get_restrict_last(1) != -1 && v0 <= v1)
            continue;

        bool is_zero = false;
        get_edge_index(v0, l, r);
        for (int prefix_id = schedule->get_last(0); prefix_id != -1; prefix_id = schedule->get_next(prefix_id))
            vertex_set[prefix_id].build_vertex_set(schedule, vertex_set, &edge[l], r - l, prefix_id);
        
        get_edge_index(v1, l, r);
        for (int prefix_id = schedule->get_last(1); prefix_id != -1; prefix_id = schedule->get_next(prefix_id)) {
            vertex_set[prefix_id].build_vertex_set(schedule, vertex_set, &edge[l], r - l, prefix_id);
            if (vertex_set[prefix_id].get_size() == 0 && prefix_id < schedule->get_basic_prefix_num()) {
                is_zero = true;
                break;
            }
        }
        if (is_zero)
            continue;
        
        unsigned long long local_sum = 0; // local sum (corresponding to an edge index)
        gpu_pattern_matching_func<2>(schedule, vertex_set, subtraction_set, tmp_set, local_sum, edge, vertex);
        sum += local_sum;
    }

    if (lid == 0) {
        atomicAdd(&dev_sum, sum);
    }
}

struct GPUContext {
    int nr_blocks, nr_total_warps, block_shmem_size;
    uint32_t *dev_edge, *dev_edge_from, *dev_vertex, *dev_tmp;
    GPUSchedule *dev_schedule;    
};

void init_gpu_schedule(GPUContext& ctx, const Schedule_IEP& sched) {
    GPUSchedule *dev_schedule;
    gpu_check( cudaMallocManaged((void**)&dev_schedule, sizeof(GPUSchedule)) );

    int n = sched.get_size();
    int max_prefix_num = n * (n - 1) / 2;
    
    auto only_need_size = new bool[max_prefix_num];
    for (int i = 0; i < max_prefix_num; ++i)
        only_need_size[i] = sched.get_prefix_only_need_size(i);

    int in_exclusion_optimize_vertex_id_size = sched.in_exclusion_optimize_vertex_id.size();
    int in_exclusion_optimize_array_size = sched.in_exclusion_optimize_coef.size();

    auto in_exclusion_optimize_vertex_id = &(sched.in_exclusion_optimize_vertex_id[0]);
    auto in_exclusion_optimize_vertex_coef = &(sched.in_exclusion_optimize_vertex_coef[0]);
    auto in_exclusion_optimize_vertex_flag = new bool[in_exclusion_optimize_vertex_id_size]; 

    auto in_exclusion_optimize_coef = &(sched.in_exclusion_optimize_coef[0]);
    auto in_exclusion_optimize_ans_pos = &(sched.in_exclusion_optimize_ans_pos[0]);
    auto in_exclusion_optimize_flag = new bool[in_exclusion_optimize_array_size];

    for (int i = 0; i < in_exclusion_optimize_vertex_id_size; ++i)
        in_exclusion_optimize_vertex_flag[i] = sched.in_exclusion_optimize_vertex_flag[i];
    
    for (int i = 0; i < in_exclusion_optimize_array_size; ++i)
        in_exclusion_optimize_flag[i] = sched.in_exclusion_optimize_flag[i];

    gpu_check( cudaMallocManaged((void**)&dev_schedule->in_exclusion_optimize_vertex_id, sizeof(int) * in_exclusion_optimize_vertex_id_size));
    gpu_check( cudaMemcpy(dev_schedule->in_exclusion_optimize_vertex_id, in_exclusion_optimize_vertex_id, sizeof(int) * in_exclusion_optimize_vertex_id_size, cudaMemcpyHostToDevice));
    
    gpu_check( cudaMallocManaged((void**)&dev_schedule->in_exclusion_optimize_vertex_flag, sizeof(bool) * in_exclusion_optimize_vertex_id_size));
    gpu_check( cudaMemcpy(dev_schedule->in_exclusion_optimize_vertex_flag, in_exclusion_optimize_vertex_flag, sizeof(bool) * in_exclusion_optimize_vertex_id_size, cudaMemcpyHostToDevice));
    
    gpu_check( cudaMallocManaged((void**)&dev_schedule->in_exclusion_optimize_vertex_coef, sizeof(int) * in_exclusion_optimize_vertex_id_size));
    gpu_check( cudaMemcpy(dev_schedule->in_exclusion_optimize_vertex_coef, in_exclusion_optimize_vertex_coef, sizeof(int) * in_exclusion_optimize_vertex_id_size, cudaMemcpyHostToDevice));

    gpu_check( cudaMallocManaged((void**)&dev_schedule->in_exclusion_optimize_coef, sizeof(int) * in_exclusion_optimize_array_size));
    gpu_check( cudaMemcpy(dev_schedule->in_exclusion_optimize_coef, in_exclusion_optimize_coef, sizeof(int) * in_exclusion_optimize_array_size, cudaMemcpyHostToDevice));

    gpu_check( cudaMallocManaged((void**)&dev_schedule->in_exclusion_optimize_flag, sizeof(bool) * in_exclusion_optimize_array_size));
    gpu_check( cudaMemcpy(dev_schedule->in_exclusion_optimize_flag, in_exclusion_optimize_flag, sizeof(bool) * in_exclusion_optimize_array_size, cudaMemcpyHostToDevice));
    
    gpu_check( cudaMallocManaged((void**)&dev_schedule->in_exclusion_optimize_ans_pos, sizeof(int) * in_exclusion_optimize_array_size));
    gpu_check( cudaMemcpy(dev_schedule->in_exclusion_optimize_ans_pos, in_exclusion_optimize_ans_pos, sizeof(int) * in_exclusion_optimize_array_size, cudaMemcpyHostToDevice));

    gpu_check( cudaMallocManaged((void**)&dev_schedule->adj_mat, sizeof(int) * n * n));
    gpu_check( cudaMemcpy(dev_schedule->adj_mat, sched.get_adj_mat_ptr(), sizeof(int) * n * n, cudaMemcpyHostToDevice));

    gpu_check( cudaMallocManaged((void**)&dev_schedule->father_prefix_id, sizeof(int) * max_prefix_num));
    gpu_check( cudaMemcpy(dev_schedule->father_prefix_id, sched.get_father_prefix_id_ptr(), sizeof(int) * max_prefix_num, cudaMemcpyHostToDevice));

    gpu_check( cudaMallocManaged((void**)&dev_schedule->last, sizeof(int) * n));
    gpu_check( cudaMemcpy(dev_schedule->last, sched.get_last_ptr(), sizeof(int) * n, cudaMemcpyHostToDevice));

    gpu_check( cudaMallocManaged((void**)&dev_schedule->next, sizeof(int) * max_prefix_num));
    gpu_check( cudaMemcpy(dev_schedule->next, sched.get_next_ptr(), sizeof(int) * max_prefix_num, cudaMemcpyHostToDevice));
    
    gpu_check( cudaMallocManaged((void**)&dev_schedule->only_need_size, sizeof(bool) * max_prefix_num));
    gpu_check( cudaMemcpy(dev_schedule->only_need_size, only_need_size, sizeof(bool) * max_prefix_num, cudaMemcpyHostToDevice));
    
    gpu_check( cudaMallocManaged((void**)&dev_schedule->break_size, sizeof(int) * max_prefix_num));
    gpu_check( cudaMemcpy(dev_schedule->break_size, sched.get_break_size_ptr(), sizeof(int) * max_prefix_num, cudaMemcpyHostToDevice));

    gpu_check( cudaMallocManaged((void**)&dev_schedule->loop_set_prefix_id, sizeof(int) * n));
    gpu_check( cudaMemcpy(dev_schedule->loop_set_prefix_id, sched.get_loop_set_prefix_id_ptr(), sizeof(int) * n, cudaMemcpyHostToDevice));

    gpu_check( cudaMallocManaged((void**)&dev_schedule->restrict_last, sizeof(int) * n));
    gpu_check( cudaMemcpy(dev_schedule->restrict_last, sched.get_restrict_last_ptr(), sizeof(int) * n, cudaMemcpyHostToDevice));
    
    gpu_check( cudaMallocManaged((void**)&dev_schedule->restrict_next, sizeof(int) * max_prefix_num));
    gpu_check( cudaMemcpy(dev_schedule->restrict_next, sched.get_restrict_next_ptr(), sizeof(int) * max_prefix_num, cudaMemcpyHostToDevice));
    
    gpu_check( cudaMallocManaged((void**)&dev_schedule->restrict_index, sizeof(int) * max_prefix_num));
    gpu_check( cudaMemcpy(dev_schedule->restrict_index, sched.get_restrict_index_ptr(), sizeof(int) * max_prefix_num, cudaMemcpyHostToDevice));

    dev_schedule->in_exclusion_optimize_array_size = in_exclusion_optimize_array_size;
    dev_schedule->in_exclusion_optimize_vertex_id_size = in_exclusion_optimize_vertex_id_size;
    dev_schedule->size = n;
    dev_schedule->total_prefix_num = sched.get_total_prefix_num();
    dev_schedule->basic_prefix_num = sched.get_basic_prefix_num();
    dev_schedule->total_restrict_num = sched.get_total_restrict_num();
    dev_schedule->in_exclusion_optimize_num = sched.get_in_exclusion_optimize_num();

    uint32_t block_shmem_size = (sched.get_total_prefix_num() + 2) * WARPS_PER_BLOCK 
        * sizeof(GPUVertexSet) + in_exclusion_optimize_vertex_id_size * WARPS_PER_BLOCK * sizeof(int);
    dev_schedule->ans_array_offset = block_shmem_size - in_exclusion_optimize_vertex_id_size * WARPS_PER_BLOCK * sizeof(int);

    ctx.block_shmem_size = block_shmem_size;
    ctx.dev_schedule = dev_schedule;

    delete[] only_need_size;
    delete[] in_exclusion_optimize_vertex_flag;
    delete[] in_exclusion_optimize_flag;
}

void init_gpu_context(GPUContext& ctx, Graph* g, const Schedule_IEP& schedule) {
    ctx.nr_blocks = 1024;
    ctx.nr_total_warps = ctx.nr_blocks * WARPS_PER_BLOCK;

    size_t size_edge = g->e_cnt * sizeof(uint32_t);
    size_t size_vertex = (g->v_cnt + 1) * sizeof(uint32_t);
    size_t size_tmp = VertexSet::max_intersection_size * sizeof(uint32_t) 
        * ctx.nr_total_warps * (schedule.get_total_prefix_num() + 2); //prefix + subtraction + tmp

    gpu_check( cudaMalloc((void**)&ctx.dev_edge, size_edge));
    gpu_check( cudaMalloc((void**)&ctx.dev_edge_from, size_edge));
    gpu_check( cudaMalloc((void**)&ctx.dev_vertex, size_vertex));
    gpu_check( cudaMalloc((void**)&ctx.dev_tmp, size_tmp));

    gpu_check( cudaMemcpy(ctx.dev_edge, g->edge, size_edge, cudaMemcpyHostToDevice));
    gpu_check( cudaMemcpy(ctx.dev_edge_from, g->edge_from, size_edge, cudaMemcpyHostToDevice));
    gpu_check( cudaMemcpy(ctx.dev_vertex, g->vertex, size_vertex, cudaMemcpyHostToDevice));

    init_gpu_schedule(ctx, schedule);
}

void free_gpu_context(GPUContext& ctx) {
    // TODO
}

struct SpinLock {
    std::atomic_flag flag;

    SpinLock() : flag{ATOMIC_FLAG_INIT} {}
    void lock() { while (flag.test_and_set()) asm volatile ("pause"); }
    void unlock() { flag.clear(); }
};

template <typename Lock>
struct LockGuard {
    Lock &_lock;
    LockGuard(Lock &lock) : _lock{lock} { _lock.lock(); }
    ~LockGuard() { _lock.unlock(); }
};

__global__ void cuda_kernel(int node)
{
    printf("hello from cuda thread=%d block=%d got rank=%d\n", threadIdx.x, blockIdx.x, node);
}

__global__ void spin_kernel(clock_t cycles)
{
    clock_t start = clock64();
    while (clock64() - start < cycles)
        ;
    printf("spin_kernel done. thread=%d\n", threadIdx.x);
}

// #define log(fmt, ...) fprintf(stderr, fmt, ##__VA_ARGS__)
#define log(fmt, ...) (void)(fmt)

// shared by all threads
int nr_tasks;
using TaskStatus = std::tuple<int, int>;
TaskStatus task_status;
SpinLock task_status_lock;
volatile bool workers_should_stop = false;
volatile bool task_requested = false;
bool *workers_idle;

constexpr int CPU_WORKER_TASK_GRANULARITY = 10;
constexpr int GPU_WORKER_TASK_GRANULARITY = 5000;
constexpr int NODE_TASK_GRANULARUTY = 10000;
constexpr int INITIAL_NODE_TASKS = 10000;

enum MessageType {
    MSG_REQUEST_WORK,  // slave -> master
    MSG_DISPATCH_WORK, // master -> slave
    MSG_REPORT_ANS     // slave -> master
};

enum NodeState {
    WORKING, // normal working state
    WAITING  // no more work from master node, waiting for worker threads to finish
};

NodeState state = WORKING; // only used by scheduler thread
int global_cur_task; // only scheduler thread of master node will modify this var in working phase
int nr_idle_nodes = 0;
uint64_t global_ans = 0, gpu_ans = 0;
std::atomic<uint64_t> node_ans{0};

void process_message(uint64_t recv_buf[], uint64_t send_buf[], int node, int sender)
{
    MPI_Request send_req;
    switch (recv_buf[0]) {
    case MSG_REQUEST_WORK: { // me: master
        send_buf[0] = MSG_DISPATCH_WORK;
        send_buf[1] = global_cur_task;
        send_buf[2] = global_cur_task = std::min(global_cur_task + NODE_TASK_GRANULARUTY, nr_tasks);
        MPI_Isend(send_buf, 3, MPI_UINT64_T, sender, 0, MPI_COMM_WORLD, &send_req);
        log("master got work request from node %d, replying [%ld, %ld)\n", sender, send_buf[1], send_buf[2]);
        break;
    }
    case MSG_DISPATCH_WORK: { // me: slave
        int new_task_cur = recv_buf[1];
        int new_task_end = recv_buf[2];
        if (new_task_cur >= nr_tasks) {
            state = NodeState::WAITING;
            log("slave node %d enters WAITING state\n", node);
        } else {
            LockGuard<SpinLock> guard{task_status_lock};
            task_status = std::make_tuple(new_task_cur, new_task_end);
            log("slave node %d got task [%d, %d)\n", node, new_task_cur, new_task_end);
            task_requested = false;
        }
        break;
    }
    case MSG_REPORT_ANS: { // me: master
        ++nr_idle_nodes;
        global_ans += recv_buf[1];
        log("master receive answer %ld from node %d\n", recv_buf[1], sender);
        break;
    }
    }
}

// TODO: require lock?
bool all_workers_idle()
{
    int nr_threads = omp_get_max_threads();
    int idle_count = 0;
    for (int i = 0; i < nr_threads; ++i)
        if (workers_idle[i])
            ++idle_count;
    return idle_count == nr_threads;
}

// TODO: returns true when too many worker threads are idle?
bool should_request_work()
{
    LockGuard<SpinLock> guard{task_status_lock};
    return std::get<0>(task_status) >= std::get<1>(task_status);
}

// returns whether task status is successfully updated
bool update_task_range(std::tuple<int, int>& task_range, int max_nr_tasks)
{
    int task_cur, task_end, new_task_cur;
    LockGuard<SpinLock> guard{task_status_lock};
    std::tie(task_cur, task_end) = task_status;
    if (task_cur < task_end) {
        new_task_cur = std::min(task_cur + max_nr_tasks, task_end);
        task_range = std::make_tuple(task_cur, new_task_cur);
        task_status = std::make_tuple(new_task_cur, task_end);
        return true;
    }
    return false;
}

void launch_pattern_matching_kernel(const GPUContext& ctx, const TaskStatus& task_range) {
    int task_cur = std::get<0>(task_range);
    int task_end = std::get<1>(task_range);
    unsigned long long sum = 0;
    gpu_check( cudaMemcpyToSymbol(dev_sum, &sum, sizeof(sum)) );
    gpu_check( cudaMemcpyToSymbol(dev_cur_task, &task_cur, sizeof(task_cur)) );
    gpu_pattern_matching<<<ctx.nr_blocks, THREADS_PER_BLOCK, ctx.block_shmem_size>>>(
        task_end, VertexSet::max_intersection_size, ctx.dev_edge_from,
        ctx.dev_edge, ctx.dev_vertex, ctx.dev_tmp, ctx.dev_schedule
    );
}

// thread 0 is scheduler
void scheduler_loop(Graph* g, const Schedule_IEP& sched, int node, int comm_sz)
{
    GPUContext ctx;
    init_gpu_context(ctx, g, sched);

    cudaEvent_t event;
    cudaEventCreate(&event);
    TaskStatus gpu_task_range;
    bool gpu_working = false;

    constexpr int MSG_BUF_LEN = 256;
    static uint64_t recv_buf[MSG_BUF_LEN], send_buf[MSG_BUF_LEN];
    MPI_Request send_req, recv_req;
    MPI_Status mpi_status;

    MPI_Irecv(recv_buf, MSG_BUF_LEN, MPI_UINT64_T, MPI_ANY_SOURCE, 0, MPI_COMM_WORLD, &recv_req);
    while (true) {
        if (node == 0 || state == NodeState::WORKING) {
            int msg_received = 0;
            MPI_Test(&recv_req, &msg_received, &mpi_status);
            if (msg_received) {
                process_message(recv_buf, send_buf, node, mpi_status.MPI_SOURCE);
                MPI_Irecv(recv_buf, MSG_BUF_LEN, MPI_UINT64_T, MPI_ANY_SOURCE, 0, MPI_COMM_WORLD, &recv_req);
            }
        }
        
        switch (state) {
        case NodeState::WORKING: {
            if (should_request_work()) {
                if (node != 0) {
                    if (!task_requested) {
                        send_buf[0] = MSG_REQUEST_WORK;
                        MPI_Isend(send_buf, 1, MPI_UINT64_T, 0, 0, MPI_COMM_WORLD, &send_req);
                        task_requested = true;
                    }
                } else {
                    int new_task_cur, new_task_end;
                    new_task_cur = global_cur_task;
                    new_task_end = global_cur_task = std::min(global_cur_task + NODE_TASK_GRANULARUTY, nr_tasks);
                    if (new_task_cur >= nr_tasks) {
                        state = NodeState::WAITING;
                        log("master node enters WAITING state\n");
                    } else {
                        LockGuard<SpinLock> guard{task_status_lock};
                        task_status = std::make_tuple(new_task_cur, new_task_end);
                        log("master node got task [%d, %d)\n", new_task_cur, new_task_end);
                    }
                }
            }
            break;
        }
        case NodeState::WAITING: {
            if (all_workers_idle()) {
                workers_should_stop = true;
                if (node != 0) {
                    send_buf[0] = MSG_REPORT_ANS;
                    send_buf[1] = node_ans;
                    MPI_Isend(send_buf, 2, MPI_UINT64_T, 0, 0, MPI_COMM_WORLD, &send_req);
                    return;
                } else {
                    if (nr_idle_nodes == comm_sz - 1)
                        return;
                }
            }
            break;
        }
        }

        if (!gpu_working) {
            if (update_task_range(gpu_task_range, GPU_WORKER_TASK_GRANULARITY)) {
                gpu_working = true;
                workers_idle[0] = false;
                launch_pattern_matching_kernel(ctx, gpu_task_range);
                cudaEventRecord(event);
                log("node %d gpu kernel launched. [%d, %d)\n", node, std::get<0>(gpu_task_range), std::get<1>(gpu_task_range));
            }
        } else { // poll gpu task state
            auto result = cudaEventQuery(event);
            if (cudaErrorNotReady == result)
                continue;
            
            assert(cudaSuccess == result);
            cudaDeviceSynchronize();

            unsigned long long sum;
            gpu_check( cudaMemcpyFromSymbol(&sum, dev_sum, sizeof(sum)) );
            node_ans += sum;
            gpu_ans  += sum;
            gpu_working = false;
            workers_idle[0] = true;
        }
    }

    free_gpu_context(ctx);
}

// other threads are workers
void worker_loop(Graph* g, const Schedule_IEP& sched, int node)
{
    // prepare data structures for pattern matching
    auto ans_buffer = new int[sched.in_exclusion_optimize_vertex_id.size()];
    auto vertex_sets = new VertexSet[sched.get_total_prefix_num()];
    VertexSet partial_embedding, tmp_set;
    partial_embedding.init();

    int thread_id = omp_get_thread_num();
    while (!workers_should_stop) {
        TaskStatus task_range;
        bool idle = !update_task_range(task_range, CPU_WORKER_TASK_GRANULARITY);
        if (idle) {
            workers_idle[thread_id] = true;
            continue;
        }
        workers_idle[thread_id] = false;
        
        int task_begin, task_end;
        std::tie(task_begin, task_end) = task_range;
        log("node %d thread %d do work [%d, %d)\n", node, thread_id, task_begin, task_end);

        uint64_t ans = 0;
        for (int i = task_begin; i < task_end; ++i)
            ans += g->pattern_matching_edge_task(sched, i, vertex_sets, partial_embedding, tmp_set, ans_buffer);
        node_ans += ans;
    }

    // release resources
    delete[] ans_buffer;
    delete[] vertex_sets;
}

void test_cuda_event()
{
    cudaEvent_t event;
    cudaEventCreate(&event);
    spin_kernel<<<1, 32>>>(1000000000); // ~ 1s, 1e9
    cudaEventRecord(event);
    while (true) {
        auto result = cudaEventQuery(event);
        if (cudaSuccess == result)
            break;
        if (cudaErrorNotReady == result) {
            printf("waiting for device...\n");
            usleep(100000);
        } else {
            printf("oops.. %s\n", cudaGetErrorString(result));
            break;
        }
    }
}

int main(int argc, char* argv[])
{
    // load graph & build schedule
    if (argc < 4) {
        fprintf(stderr, "Usage: %s graph_file [ignored] pattern_string\n", argv[0]);
        return 0;
    }

    Graph *g;
    DataLoader D;
    if (!D.fast_load(g, argv[1])) {
        fprintf(stderr, "Unable to load graph from %s\n", argv[1]);
        return 0;
    }
    g->build_reverse_edges();

    std::string pattern_str = argv[3];
    Pattern p(int(sqrt(pattern_str.length())), pattern_str.c_str());

    bool pattern_valid;
    Schedule_IEP schedule{p, pattern_valid, 1, 1, true, g->v_cnt, g->e_cnt, g->tri_cnt};
    if (!pattern_valid) {
        fprintf(stderr, "invalid pattern %s\n", argv[3]);
        return 0;
    }

    // MPI initialization
    int comm_sz, node;
    MPI_Init(&argc, &argv);
    MPI_Comm_size(MPI_COMM_WORLD, &comm_sz);
    MPI_Comm_rank(MPI_COMM_WORLD, &node);
    fprintf(stderr, "size = %d rank = %d\n", comm_sz, node);

    // initialize global work states
    nr_tasks = g->e_cnt;
    int nr_threads = omp_get_max_threads();
    workers_idle = new bool[nr_threads] {true};
    // init task_status, global_cur_task
    // warn: make sure nr_tasks >= comm_sz * INITIAL_NODE_TASKS
    int initial_task = node * INITIAL_NODE_TASKS;
    task_status = std::make_tuple(initial_task, initial_task + INITIAL_NODE_TASKS);
    global_cur_task = comm_sz * INITIAL_NODE_TASKS;

    using std::chrono::system_clock;
    auto t1 = system_clock::now();
    #pragma omp parallel
    {
        int thread_id = omp_get_thread_num();
        if (thread_id == 0) {
            scheduler_loop(g, schedule, node, comm_sz);
        } else {
            worker_loop(g, schedule, node);
        }
        log("node %d thread %d finish.\n", node, thread_id);
    }
    auto t2 = system_clock::now();
    auto elapsed = std::chrono::duration_cast<std::chrono::microseconds>(t2 - t1);
    
    if (node == 0) {
        auto final_ans = (global_ans + node_ans) / schedule.get_in_exclusion_optimize_redundancy();
        printf("final answer = %ld\n", final_ans);
        printf("time = %g seconds\n", elapsed.count() / 1e6);
    }
    printf("node %d node_ans = %ld gpu_ans = %ld\n", node, uint64_t(node_ans), gpu_ans);
    MPI_Finalize();
    return 0;
}
