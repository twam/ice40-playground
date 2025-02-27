/*
 * hub75_top.v
 *
 * vim: ts=4 sw=4
 *
 * Copyright (C) 2019  Sylvain Munaut <tnt@246tNt.com>
 * All rights reserved.
 *
 * LGPL v3+, see LICENSE.lgpl3
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 3 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
 */

`default_nettype none

module hub75_top #(
	parameter integer N_BANKS  = 2,		// # of parallel readout rows
	parameter integer N_ROWS   = 32,	// # of rows (must be power of 2!!!)
	parameter integer N_COLS   = 64,	// # of columns
	parameter integer N_CHANS  = 3,		// # of data channel
	parameter integer N_PLANES = 8,		// # bitplanes
	parameter integer BITDEPTH = 24,	// # bits per color

	parameter SCAN_MODE = "ZIGZAG",		// 'LINEAR' or 'ZIGZAG'

	// Auto-set
	parameter integer LOG_N_BANKS = $clog2(N_BANKS),
	parameter integer LOG_N_ROWS  = $clog2(N_ROWS),
	parameter integer LOG_N_COLS  = $clog2(N_COLS)
)(
	// Hub75 interface pads
	output wire [LOG_N_ROWS-1:0] hub75_addr,
	output wire [(N_BANKS*N_CHANS)-1:0] hub75_data,
	output wire hub75_clk,
	output wire hub75_le,
	output wire hub75_blank,

	// Frame Buffer write interface
		// Row store/swap
	input  wire [LOG_N_BANKS-1:0] fbw_bank_addr,
	input  wire [LOG_N_ROWS-1:0]  fbw_row_addr,
	input  wire fbw_row_store,
	output wire fbw_row_rdy,
	input  wire fbw_row_swap,

		// Line buffer access
	input  wire [BITDEPTH-1:0] fbw_data,
	input  wire [LOG_N_COLS-1:0] fbw_col_addr,
	input  wire fbw_wren,

		// Frame buffer swap
	input  wire frame_swap,
	output wire frame_rdy,

	// Control / Config
	input  wire ctrl_run,

	input  wire [7:0] cfg_pre_latch_len,
	input  wire [7:0] cfg_latch_len,
	input  wire [7:0] cfg_post_latch_len,
	input  wire [7:0] cfg_bcm_bit_len,

	// Clock / Reset
	input  wire clk,
	input  wire rst
);

	// Signals
	// -------

	// Frame swap logic
	reg  frame_swap_pending;
	wire frame_swap_fb;

	// PHY interface
	wire [LOG_N_ROWS-1:0] phy_addr;
	wire [(N_BANKS*N_CHANS)-1:0] phy_data;
	wire phy_clk;
	wire phy_le;
	wire phy_blank;

	// Frame Buffer access
		// Read - Back Buffer loading
	wire [LOG_N_ROWS-1:0] fbr_row_addr;
	wire fbr_row_load;
	wire fbr_row_rdy;
	wire fbr_row_swap;

		// Read - Front Buffer access
	wire [(N_BANKS*N_CHANS*N_PLANES)-1:0] fbr_data;
	wire [LOG_N_COLS-1:0] fbr_col_addr;
	wire fbr_rden;

	// Scanning
	wire scan_go;
	wire scan_rdy;

	// Binary Code Modulator
	wire [LOG_N_ROWS-1:0] bcm_row;
	wire bcm_go;
	wire bcm_rdy;

	// Shifter
	wire [N_PLANES-1:0] shift_plane;
	wire shift_go;
	wire shift_rdy;

	// Blanking control
	wire [N_PLANES-1:0] blank_plane;
	wire blank_go;
	wire blank_rdy;


	// Sub-blocks
	// ----------

	// Synchronized frame swap logic
	always @(posedge clk or posedge rst)
		if (rst)
			frame_swap_pending <= 1'b0;
		else
			frame_swap_pending <= (frame_swap_pending & ~scan_rdy) | frame_swap;

	assign frame_rdy = ~frame_swap_pending;
	assign scan_go = scan_rdy & ~frame_swap_pending & ctrl_run;
	assign frame_swap_fb = frame_swap_pending & scan_rdy;

	// The signal direction usage legend to the right of the modules has the
	// following structure:
	// * Signal direction -> (output from the module)
	// * Signal direction <- (input to the module)
	// * top: signal is connected to top and exposed to the world
	// * pad: signal is a gpio pad id the direction indicates if the pad is an
	//        input (<-), output (->) or bidir (<->)
	// * local: signal is conneted to some local module logic
	// * hub75_*: signal is connected to the module hub75_*

	// Frame Buffer
	hub75_framebuffer #(
		.N_BANKS(N_BANKS),
		.N_ROWS(N_ROWS),
		.N_COLS(N_COLS),
		.N_CHANS(N_CHANS),
		.N_PLANES(N_PLANES),
		.BITDEPTH(BITDEPTH)
	) fb_I (
		.wr_bank_addr(fbw_bank_addr),	// <- top
		.wr_row_addr(fbw_row_addr),		// <- top
		.wr_row_store(fbw_row_store),	// <- top
		.wr_row_rdy(fbw_row_rdy),		// -> top
		.wr_row_swap(fbw_row_swap),		// <- top
		.wr_data(fbw_data),				// <- top
		.wr_col_addr(fbw_col_addr),		// <- top
		.wr_en(fbw_wren),				// <- top
		.rd_row_addr(fbr_row_addr),		// <- hub75_scan
		.rd_row_load(fbr_row_load),		// <- hub75_scan
		.rd_row_rdy(fbr_row_rdy),		// -> hub75_scan
		.rd_row_swap(fbr_row_swap),		// <- hub75_scan
		.rd_data(fbr_data),				// -> hub75_shift
		.rd_col_addr(fbr_col_addr),		// <- hub75_shift
		.rd_en(fbr_rden),				// <- hub75_shift
		.frame_swap(frame_swap_fb),		// <- local
		.clk(clk),						// <- top
		.rst(rst)						// <- top
	);

	// Scan
	hub75_scan #(
		.N_ROWS(N_ROWS),
		.SCAN_MODE(SCAN_MODE)
	) scan_I (
		.bcm_row(bcm_row),				// -> hub75_bcm
		.bcm_go(bcm_go),				// -> hub75_bcm
		.bcm_rdy(bcm_rdy),				// <- hub75_bcm
		.fb_row_addr(fbr_row_addr),		// -> hub75_framebuffer
		.fb_row_load(fbr_row_load),		// -> hub75_framebuffer
		.fb_row_rdy(fbr_row_rdy),		// <- hub75_framebuffer
		.fb_row_swap(fbr_row_swap),		// -> hub75_framebuffer
		.ctrl_go(scan_go),				// <- local
		.ctrl_rdy(scan_rdy),			// -> local
		.clk(clk),						// <- top
		.rst(rst)						// <- top
	);

	// Binary Code Modulator control
	hub75_bcm #(
		.N_PLANES(N_PLANES)
	) bcm_I (
		.phy_addr(phy_addr),			// -> hub75_phy
		.phy_le(phy_le),				// -> hub75_phy
		.shift_plane(shift_plane),		// -> hub75_shift
		.shift_go(shift_go),			// -> hub75_shift
		.shift_rdy(shift_rdy),			// <- hub75_shift
		.blank_plane(blank_plane),		// -> hub75_blanking
		.blank_go(blank_go),			// -> hub75_blanking
		.blank_rdy(blank_rdy),			// <- hub75_blanking
		.ctrl_row(bcm_row),				// <- hub75_scan
		.ctrl_go(bcm_go),				// <- hub75_scan
		.ctrl_rdy(bcm_rdy),				// -> hub75_scan
		.cfg_pre_latch_len(cfg_pre_latch_len),		// <- top
		.cfg_latch_len(cfg_latch_len),				// <- top
		.cfg_post_latch_len(cfg_post_latch_len),	// <- top
		.clk(clk),						// <- top
		.rst(rst)						// <- top
	);

	// Shifter
	hub75_shift #(
		.N_BANKS(N_BANKS),
		.N_COLS(N_COLS),
		.N_CHANS(N_CHANS),
		.N_PLANES(N_PLANES)
	) shift_I (
		.phy_data(phy_data),			// -> hub75_phy
		.phy_clk(phy_clk),				// -> hub75_phy
		.ram_data(fbr_data),			// <- hub75_framebuffer
		.ram_col_addr(fbr_col_addr),	// -> hub75_framebuffer
		.ram_rden(fbr_rden),			// -> hub75_framebuffer
		.ctrl_plane(shift_plane),		// <- hub75_bcm
		.ctrl_go(shift_go),				// <- hub75_bcm
		.ctrl_rdy(shift_rdy),			// -> hub75_bcm
		.clk(clk),						// <- top
		.rst(rst)						// <- top
	);

	// Blanking control
	hub75_blanking #(
		.N_PLANES(N_PLANES)
	) blank_I (
		.phy_blank(phy_blank),			// -> hub75_phy
		.ctrl_plane(blank_plane),		// <- hub75_bcm
		.ctrl_go(blank_go),				// <- hub75_bcm
		.ctrl_rdy(blank_rdy),			// -> hub75_bcm
		.cfg_bcm_bit_len(cfg_bcm_bit_len),	// <- top
		.clk(clk),						// <- top
		.rst(rst)						// <- top
	);

	// Physical layer control
	hub75_phy #(
		.N_BANKS(N_BANKS),
		.N_ROWS(N_ROWS),
		.N_CHANS(N_CHANS)
	) phy_I (
		.hub75_addr(hub75_addr),		// -> pad
		.hub75_data(hub75_data),		// -> pad
		.hub75_clk(hub75_clk),			// -> pad
		.hub75_le(hub75_le),			// -> pad
		.hub75_blank(hub75_blank),		// -> pad
		.phy_addr(phy_addr),			// <- hub75_bcm
		.phy_data(phy_data),			// <- hub75_shift
		.phy_clk(phy_clk),				// <- hub75_shift
		.phy_le(phy_le),				// <- hub75_bcm
		.phy_blank(phy_blank),			// <- hub75_blanking
		.clk(clk),						// <- top
		.rst(rst)						// <- top
	);

endmodule // hub75_top
