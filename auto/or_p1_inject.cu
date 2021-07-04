__global__ void gpu_pattern_matching(uint32_t edge_num, uint32_t buffer_size, uint32_t *edge_from, uint32_t *edge, uint32_t *vertex, uint32_t *tmp, const GPUSchedule* schedule) {
    __shared__ unsigned int block_edge_idx[WARPS_PER_BLOCK];
    extern __shared__ GPUVertexSet block_vertex_set[];
    extern __shared__ char block_shmem[];

    int wid = threadIdx.x / THREADS_PER_WARP;
    int lid = threadIdx.x % THREADS_PER_WARP;
    int global_wid = blockIdx.x * WARPS_PER_BLOCK + wid;
    unsigned int &edge_idx = block_edge_idx[wid];
    GPUVertexSet *vertex_set = block_vertex_set + wid * 6;

    GPUVertexSet &subtraction_set = vertex_set[5];
    if (lid == 0) {
        edge_idx = 0;
        uint32_t offset = buffer_size * global_wid * 5;

        uint32_t *block_subtraction_set_buf = (uint32_t *)(block_shmem + 768);
        subtraction_set.set_data_ptr(block_subtraction_set_buf + wid * 3);

        for (int i = 0; i < 5; ++i) {
            vertex_set[i].set_data_ptr(tmp + offset);
            offset += buffer_size;
        }
    }

    __threadfence_block();

    uint32_t v0, v1, v2;
    uint32_t l, r;
    unsigned long long sum = 0;

    while (true) {
        if (lid == 0) {
            edge_idx = atomicAdd(&dev_cur_edge, 1);
        }
        __threadfence_block();

        unsigned int i = edge_idx;
        if (i >= edge_num) break;

        v0 = edge_from[i];
        v1 = edge[i];
        if (v0 <= v1) continue;

        get_edge_index(v0, l, r);
        if (threadIdx.x % THREADS_PER_WARP == 0)
            vertex_set[0].init(r - l, &edge[l]);
        __threadfence_block();
        
        get_edge_index(v1, l, r);
        GPUVertexSet* tmp_vset;
        intersection2(vertex_set[1].get_data_ptr(), vertex_set[0].get_data_ptr(), &edge[l], vertex_set[0].get_size(), r - l, &vertex_set[1].size);
        if (vertex_set[1].get_size() == 0) continue;
        
        if (threadIdx.x % THREADS_PER_WARP == 0)
            vertex_set[2].init(r - l, &edge[l]);
        __threadfence_block();
        if (vertex_set[2].get_size() == 0) continue;
        
        int loop_size_depth2 = vertex_set[0].get_size();
        uint32_t* loop_data_ptr_depth2 = vertex_set[0].get_data_ptr();
        for (int i_depth2 = 0; i_depth2 < loop_size_depth2; ++i_depth2) {
            uint32_t v_depth2 = loop_data_ptr_depth2[i_depth2];
            if (v0 == v_depth2 || v1 == v_depth2) continue;

            unsigned int l_depth2, r_depth2;
            get_edge_index(v_depth2, l_depth2, r_depth2);
            {
                tmp_vset = &vertex_set[3];
                if (threadIdx.x % THREADS_PER_WARP == 0)
                    tmp_vset->init(r_depth2 - l_depth2, &edge[l_depth2]);
                __threadfence_block();
                if (r_depth2 - l_depth2 > vertex_set[2].get_size())
                    tmp_vset->size -= unordered_subtraction_size(*tmp_vset, vertex_set[2], -1);
                else
                    tmp_vset->size = vertex_set[2].get_size() - unordered_subtraction_size(vertex_set[2], *tmp_vset, -1);
            }
            if (vertex_set[3].get_size() == 1) continue;
            
            {
                tmp_vset = &vertex_set[4];
                if (threadIdx.x % THREADS_PER_WARP == 0)
                    tmp_vset->init(r_depth2 - l_depth2, &edge[l_depth2]);
                __threadfence_block();
                if (r_depth2 - l_depth2 > vertex_set[1].get_size())
                    tmp_vset->size -= unordered_subtraction_size(*tmp_vset, vertex_set[1], -1);
                else
                    tmp_vset->size = vertex_set[1].get_size() - unordered_subtraction_size(vertex_set[1], *tmp_vset, -1);
            }
            
            v2 = v_depth2; // subtraction_set.push_back(v2);

            if (lid == 0) {
                uint32_t *p = subtraction_set.get_data_ptr();
                p[0] = v0;
                p[1] = v1;
                p[2] = v2;
                subtraction_set.set_size(3);
            }
            __threadfence_block();

            int ans0 = unordered_subtraction_size(vertex_set[1], subtraction_set);
            int ans1 = vertex_set[3].get_size() - 1;
            int ans2 = vertex_set[4].get_size() - 0;
            long long val;
            val = ans0;
            val = val * ans1;
            sum += val * 1;
            val = ans2;
            sum += val * -1;
        }
    }
    if (lid == 0) atomicAdd(&dev_sum, sum);
}