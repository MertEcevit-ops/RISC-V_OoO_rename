module rename(
    input  logic       clk,
    input  logic       rst_ni,
    input  br_result_t br_result_i,
    input  p_reg_t     p_commit_i,   //in-order commit
    input  dinstr_t    dinstr_i,
    output rinstr_t    rinstr_o,
    output logic       rn_full_o
);

    // Parameters
    localparam int NUM_ARCH_REGS = 32;
    localparam int NUM_PHYS_REGS = 64;
    localparam int PHYS_REG_BITS = 6;

    // Register Alias Table (RAT) - maps architectural to physical registers
    logic [PHYS_REG_BITS-1:0] rat [NUM_ARCH_REGS];
    logic [PHYS_REG_BITS-1:0] rat_next [NUM_ARCH_REGS];
    
    // Free list - tracks available physical registers
    logic free_list [NUM_PHYS_REGS];
    logic free_list_next [NUM_PHYS_REGS];
    
    // Physical register ready bits
    logic phys_ready [NUM_PHYS_REGS];
    logic phys_ready_next [NUM_PHYS_REGS];
    
    // Branch support structures
    logic [PHYS_REG_BITS-1:0] rat_checkpoint [NUM_ARCH_REGS];
    logic [PHYS_REG_BITS-1:0] rat_checkpoint_next [NUM_ARCH_REGS];
    logic free_list_checkpoint [NUM_PHYS_REGS];
    logic free_list_checkpoint_next [NUM_PHYS_REGS];
    logic checkpoint_valid;
    logic checkpoint_valid_next;
    
    // Internal signals
    logic [PHYS_REG_BITS-1:0] free_phys_reg;
    logic free_reg_found;
    logic need_phys_reg;
    
    // Find next free physical register
    always_comb begin
        free_reg_found = 1'b0;
        free_phys_reg = 6'd0;
        
        // Start from register 1 (register 0 is special)
        for (int i = 1; i < NUM_PHYS_REGS; i++) begin
            if (free_list[i] && !free_reg_found) begin
                free_phys_reg = i[PHYS_REG_BITS-1:0];
                free_reg_found = 1'b1;
            end
        end
    end
    
    // Determine if we need a physical register
    assign need_phys_reg = dinstr_i.valid && dinstr_i.rd.valid && (dinstr_i.rd.idx != 5'd0);
    
    // Output full signal
    assign rn_full_o = need_phys_reg && !free_reg_found;
    
    // Rename logic
    always_comb begin
        rinstr_o = '0;
        
        if (dinstr_i.valid && !rn_full_o) begin
            rinstr_o.valid = 1'b1;
            
            // Handle destination register
            if (dinstr_i.rd.valid) begin
                rinstr_o.rd.valid = 1'b1;
                if (dinstr_i.rd.idx == 5'd0) begin
                    // Special case: architectural register 0 maps to physical register 0
                    rinstr_o.rd.idx = 6'd0;
                    rinstr_o.rd.ready = 1'b1; // Register 0 is always ready
                end else begin
                    rinstr_o.rd.idx = free_phys_reg;
                    rinstr_o.rd.ready = 1'b0; // New allocation, not ready yet
                end
            end
            
            // Handle source register 1
            if (dinstr_i.rs1.valid) begin
                rinstr_o.rs1.valid = 1'b1;
                if (dinstr_i.rs1.idx == 5'd0) begin
                    rinstr_o.rs1.idx = 6'd0;
                    rinstr_o.rs1.ready = 1'b1; // Register 0 is always ready
                end else begin
                    rinstr_o.rs1.idx = rat[dinstr_i.rs1.idx];
                    // Check if ready, including same-cycle commit
                    rinstr_o.rs1.ready = phys_ready[rat[dinstr_i.rs1.idx]] || 
                                       (p_commit_i.valid && p_commit_i.idx == rat[dinstr_i.rs1.idx]);
                end
            end
            
            // Handle source register 2
            if (dinstr_i.rs2.valid) begin
                rinstr_o.rs2.valid = 1'b1;
                if (dinstr_i.rs2.idx == 5'd0) begin
                    rinstr_o.rs2.idx = 6'd0;
                    rinstr_o.rs2.ready = 1'b1; // Register 0 is always ready
                end else begin
                    rinstr_o.rs2.idx = rat[dinstr_i.rs2.idx];
                    // Check if ready, including same-cycle commit
                    rinstr_o.rs2.ready = phys_ready[rat[dinstr_i.rs2.idx]] || 
                                       (p_commit_i.valid && p_commit_i.idx == rat[dinstr_i.rs2.idx]);
                end
            end
        end
    end
    
    // Next state logic
    always_comb begin
        rat_next = rat;
        free_list_next = free_list;
        phys_ready_next = phys_ready;
        checkpoint_valid_next = checkpoint_valid;
        rat_checkpoint_next = rat_checkpoint;
        free_list_checkpoint_next = free_list_checkpoint;
        
        // Handle branch misprediction recovery
        if (br_result_i.valid && !br_result_i.hit && checkpoint_valid) begin
            // Restore from checkpoint
            for (int i = 0; i < NUM_ARCH_REGS; i++) begin
                rat_next[i] = rat_checkpoint[i];
            end
            for (int i = 0; i < NUM_PHYS_REGS; i++) begin
                free_list_next[i] = free_list_checkpoint[i];
            end
            checkpoint_valid_next = 1'b0;
        end
        // Handle normal instruction processing
        else if (dinstr_i.valid && !rn_full_o) begin
            // Create checkpoint for branch instructions
            if (dinstr_i.is_branch) begin
                for (int i = 0; i < NUM_ARCH_REGS; i++) begin
                    rat_checkpoint_next[i] = rat[i];
                end
                for (int i = 0; i < NUM_PHYS_REGS; i++) begin
                    free_list_checkpoint_next[i] = free_list[i];
                end
                checkpoint_valid_next = 1'b1;
            end
            
            // Update RAT and free list for destination register
            if (dinstr_i.rd.valid && dinstr_i.rd.idx != 5'd0) begin
                // Free the old physical register
                free_list_next[rat[dinstr_i.rd.idx]] = 1'b1;
                // Update RAT with new physical register
                rat_next[dinstr_i.rd.idx] = free_phys_reg;
                // Mark new physical register as allocated
                free_list_next[free_phys_reg] = 1'b0;
            end
        end
        
        // Handle commit
        if (p_commit_i.valid) begin
            phys_ready_next[p_commit_i.idx] = 1'b1;
        end
        
        // Handle successful branch resolution
        if (br_result_i.valid && br_result_i.hit) begin
            checkpoint_valid_next = 1'b0;
        end
    end
    
    // Sequential logic
    always_ff @(posedge clk or negedge rst_ni) begin
        if (!rst_ni) begin
            // Initialize RAT - each architectural register maps to itself initially
            for (int i = 0; i < NUM_ARCH_REGS; i++) begin
                rat[i] <= i[PHYS_REG_BITS-1:0];
            end
            
            // Initialize free list - first NUM_ARCH_REGS are allocated, rest are free
            for (int i = 0; i < NUM_PHYS_REGS; i++) begin
                if (i < NUM_ARCH_REGS) begin
                    free_list[i] <= 1'b0; // Allocated
                end else begin
                    free_list[i] <= 1'b1; // Free
                end
            end
            
            // Initialize physical register ready bits
            for (int i = 0; i < NUM_PHYS_REGS; i++) begin
                phys_ready[i] <= 1'b1; // All initially ready
            end
            
            checkpoint_valid <= 1'b0;
        end else begin
            rat <= rat_next;
            free_list <= free_list_next;
            phys_ready <= phys_ready_next;
            checkpoint_valid <= checkpoint_valid_next;
            rat_checkpoint <= rat_checkpoint_next;
            free_list_checkpoint <= free_list_checkpoint_next;
        end
    end

endmodule