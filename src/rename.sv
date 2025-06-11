module rename(
    input  logic       clk_i,
    input  logic       rst_ni,
    input  br_result_t br_result_i,
    input  p_reg_t     p_commit_i,   //in-order commit
    input  dinstr_t    dinstr_i,
    output rinstr_t    rinstr_o,
    output logic       rn_full_o
);

    // Parameters
    localparam int ARCH_REGS = 32;  // x0-x31
    localparam int PHYS_REGS = 64;  // 64 physical registers
    
    // Register Alias Table (RAT) - maps architectural to physical registers
    logic [5:0] rat [ARCH_REGS-1:0];
    
    // Free list - tracks available physical registers
    logic [PHYS_REGS-1:0] free_list;
    logic [5:0] next_free_ptr;
    
    // Physical register ready bits
    logic [PHYS_REGS-1:0] phys_ready;
    
    // Branch support structures (bonus)
    logic [5:0] rat_checkpoint [ARCH_REGS-1:0];
    logic [PHYS_REGS-1:0] free_list_checkpoint;
    logic branch_active;
    
    // Internal signals
    logic [5:0] allocated_reg;
    logic has_free_reg;
    logic need_free_reg;
    logic [5:0] rs1_phys, rs2_phys;
    logic rs1_ready, rs2_ready;
    
    // Find next free register
    always_comb begin
        allocated_reg = 6'b0;
        has_free_reg = 1'b0;
        
        // Start from register 32 (first free register after architectural ones)
        for (int i = 32; i < PHYS_REGS; i++) begin
            if (free_list[i]) begin
                allocated_reg = i[5:0];
                has_free_reg = 1'b1;
                break;
            end
        end
    end
    
    // Determine if we need a free register
    assign need_free_reg = dinstr_i.valid && dinstr_i.rd.valid && (dinstr_i.rd.idx != 5'b0);
    
    // Output full signal
    assign rn_full_o = need_free_reg && !has_free_reg;
    
    // Source register mapping
    assign rs1_phys = (dinstr_i.rs1.valid) ? rat[dinstr_i.rs1.idx] : 6'b0;
    assign rs2_phys = (dinstr_i.rs2.valid) ? rat[dinstr_i.rs2.idx] : 6'b0;
    
    // Ready status - check if committed or being committed this cycle
    assign rs1_ready = (dinstr_i.rs1.idx == 5'b0) ? 1'b1 : 
                       (phys_ready[rs1_phys] || (p_commit_i.valid && p_commit_i.idx == rs1_phys));
    
    assign rs2_ready = (dinstr_i.rs2.idx == 5'b0) ? 1'b1 : 
                       (phys_ready[rs2_phys] || (p_commit_i.valid && p_commit_i.idx == rs2_phys));
    
    // Main rename logic
    always_comb begin
        // Default output
        rinstr_o = '0;
        
        if (dinstr_i.valid && !rn_full_o) begin
            rinstr_o.valid = 1'b1;
            
            // Handle destination register
            if (dinstr_i.rd.valid) begin
                rinstr_o.rd.valid = 1'b1;
                if (dinstr_i.rd.idx == 5'b0) begin
                    // x0 always maps to p0
                    rinstr_o.rd.idx = 6'b0;
                    rinstr_o.rd.ready = 1'b1; // x0 is always ready (but will be overwritten)
                end else begin
                    // Allocate new physical register
                    rinstr_o.rd.idx = allocated_reg;
                    rinstr_o.rd.ready = 1'b0; // New register is not ready initially
                end
            end
            
            // Handle source register 1
            if (dinstr_i.rs1.valid) begin
                rinstr_o.rs1.valid = 1'b1;
                rinstr_o.rs1.idx = rs1_phys;
                rinstr_o.rs1.ready = rs1_ready;
            end
            
            // Handle source register 2
            if (dinstr_i.rs2.valid) begin
                rinstr_o.rs2.valid = 1'b1;
                rinstr_o.rs2.idx = rs2_phys;
                rinstr_o.rs2.ready = rs2_ready;
            end
        end
    end
    
    // Sequential logic
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            // Initialize RAT - each architectural register maps to itself initially
            for (int i = 0; i < ARCH_REGS; i++) begin
                rat[i] <= i[5:0];
                if (i < ARCH_REGS) rat_checkpoint[i] <= i[5:0];
            end
            
            // Initialize free list - registers 32-63 are free initially
            free_list <= '0;
            for (int i = 32; i < PHYS_REGS; i++) begin
                free_list[i] <= 1'b1;
            end
            free_list_checkpoint <= '0;
            for (int i = 32; i < PHYS_REGS; i++) begin
                free_list_checkpoint[i] <= 1'b1;
            end
            
            // Initialize physical register ready bits
            // Registers 0-31 are ready initially (architectural state)
            phys_ready <= '0;
            for (int i = 0; i < 32; i++) begin
                phys_ready[i] <= 1'b1;
            end
            
            branch_active <= 1'b0;
            
        end else begin
            // Handle branch resolution (bonus feature)
            if (br_result_i.valid && branch_active) begin
                branch_active <= 1'b0;
                if (!br_result_i.hit) begin
                    // Branch misprediction - restore checkpoint
                    for (int i = 0; i < ARCH_REGS; i++) begin
                        rat[i] <= rat_checkpoint[i];
                    end
                    free_list <= free_list_checkpoint;
                end
            end
            
            // Handle commit - mark physical register as ready
            if (p_commit_i.valid) begin
                phys_ready[p_commit_i.idx] <= 1'b1;
            end
            
            // Handle new instruction
            if (dinstr_i.valid && !rn_full_o) begin
                // Create checkpoint for branch instruction (bonus)
                if (dinstr_i.is_branch) begin
                    for (int i = 0; i < ARCH_REGS; i++) begin
                        rat_checkpoint[i] <= rat[i];
                    end
                    free_list_checkpoint <= free_list;
                    branch_active <= 1'b1;
                end
                
                // Update RAT and free list for destination register
                if (dinstr_i.rd.valid && dinstr_i.rd.idx != 5'b0) begin
                    // Update RAT to point to new physical register
                    rat[dinstr_i.rd.idx] <= allocated_reg;
                    
                    // Mark the allocated register as not free
                    free_list[allocated_reg] <= 1'b0;
                    
                    // Mark the new physical register as not ready
                    phys_ready[allocated_reg] <= 1'b0;
                end
            end
        end
    end

endmodule
