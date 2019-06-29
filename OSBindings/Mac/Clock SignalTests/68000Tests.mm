//
//  68000Tests.m
//  Clock SignalTests
//
//  Created by Thomas Harte on 13/03/2019.
//  Copyright © 2019 Thomas Harte. All rights reserved.
//

#import <XCTest/XCTest.h>

#include <cassert>

#include "TestRunner68000.hpp"

class CPU::MC68000::ProcessorStorageTests {
	public:
		ProcessorStorageTests(const CPU::MC68000::ProcessorStorage &storage, const char *coverage_file_name) {
			false_valids_ = [NSMutableSet set];
			false_invalids_ = [NSMutableSet set];

			FILE *source = fopen(coverage_file_name, "rb");

			// The file format here is [2 bytes opcode][2 ASCII characters:VA for valid, IN for invalid]...
			// The file terminates with four additional bytes that begin with two zero bytes.
			//
			// The version of the file I grabbed seems to cover all opcodes, making their enumeration
			// arguably redundant; the code below nevertheless uses the codes from the file.
			//
			// Similarly, I'm testing for exactly the strings VA or IN to ensure no further
			// types creep into any updated version of the table that I then deal with incorrectly.
			uint16_t last_observed = 0;
			while(true) {
				// Fetch opcode number.
				uint16_t next_opcode = fgetc(source) << 8;
				next_opcode |= fgetc(source);
				if(next_opcode < last_observed) break;
				last_observed = next_opcode;

				// Determine whether it's meant to be valid.
				char type[3];
				type[0] = fgetc(source);
				type[1] = fgetc(source);
				type[2] = '\0';

				// TEMPORARY: factor out A- and F-line exceptions.
				if((next_opcode&0xf000) == 0xa000) continue;
				if((next_opcode&0xf000) == 0xf000) continue;

				if(!strcmp(type, "VA")) {
					// Test for validity.
					if(!storage.instructions[next_opcode].micro_operations) {
						[false_invalids_ addObject:@(next_opcode)];
					}
					continue;
				}

				if(!strcmp(type, "IN")) {
					// Test for invalidity.
					if(storage.instructions[next_opcode].micro_operations) {
						[false_valids_ addObject:@(next_opcode)];
					}
					continue;
				}

				assert(false);
			}

			fclose(source);
		}

		NSSet<NSNumber *> *false_valids() const {
			return false_valids_;
		}

		NSSet<NSNumber *> *false_invalids() const {
			return false_invalids_;
		}

	private:
		NSMutableSet<NSNumber *> *false_invalids_;
		NSMutableSet<NSNumber *> *false_valids_;
};

@interface NSSet (CSHexDump)

- (NSString *)hexDump;

@end

@implementation NSSet (CSHexDump)

- (NSString *)hexDump {
	NSMutableArray<NSString *> *components = [NSMutableArray array];

	for(NSNumber *number in [[self allObjects] sortedArrayUsingSelector:@selector(compare:)]) {
		[components addObject:[NSString stringWithFormat:@"%04x", number.intValue]];
	}

	return [components componentsJoinedByString:@" "];
}

@end


@interface M68000Tests : XCTestCase
@end

@implementation M68000Tests {
	std::unique_ptr<RAM68000> _machine;
}

- (void)setUp {
    _machine.reset(new RAM68000());
}

- (void)tearDown {
	_machine.reset();
}

- (void)testABCDLong {
	for(int d = 0; d < 100; ++d) {
		_machine.reset(new RAM68000());
		_machine->set_program({
			0xc100		// ABCD D0, D0
		});

		auto state = _machine->get_processor_state();
		const uint8_t bcd_d = ((d / 10) * 16) + (d % 10);
		state.data[0] = bcd_d;
		_machine->set_processor_state(state);

		_machine->run_for_instructions(1);

		state = _machine->get_processor_state();
		const uint8_t double_d = (d * 2) % 100;
		const uint8_t bcd_double_d = ((double_d / 10) * 16) + (double_d % 10);
		XCTAssert(state.data[0] == bcd_double_d, "%02x + %02x = %02x; should equal %02x", bcd_d, bcd_d, state.data[0], bcd_double_d);
	}
}

- (void)testDivideByZero {
	_machine->set_program({
		0x7000,		// MOVE #0, D0;		location 0x400
		0x3200,		// MOVE D0, D1;		location 0x402

		0x82C0,		// DIVU;			location 0x404

		/* Next instruction would be at 0x406 */
	});
	_machine->set_initial_stack_pointer(0x1000);

	_machine->run_for_instructions(4);

	const auto state = _machine->get_processor_state();
	XCTAssert(state.supervisor_stack_pointer == 0x1000 - 6, @"Exception information should have been pushed to stack.");

	const uint16_t *const stack_top = _machine->ram_at(state.supervisor_stack_pointer);
	XCTAssert(stack_top[1] == 0x0000 && stack_top[2] == 0x1006, @"Return address should point to instruction after DIVU.");
}

- (void)testMOVE {
	_machine->set_program({
		0x303c, 0xfb2e,		// MOVE #fb2e, D0
		0x3200,				// MOVE D0, D1

		0x3040,				// MOVEA D0, A0
		0x3278, 0x1000,		// MOVEA.w (0x1000), A1

		0x387c, 0x1000,		// MOVE #$1000, A4
		0x2414,				// MOVE.l (A4), D2
	});

	// run_for_instructions technically runs up to the next instruction
	// fetch; therefore run for '1' to get past the implied RESET.
	_machine->run_for_instructions(1);

	// Perform MOVE #fb2e, D0
	_machine->run_for_instructions(1);
	auto state = _machine->get_processor_state();
	XCTAssert(state.data[0] == 0xfb2e);

	// Perform MOVE D0, D1
	_machine->run_for_instructions(1);
	state = _machine->get_processor_state();
	XCTAssert(state.data[1] == 0xfb2e);

	// Perform MOVEA D0, A0
	_machine->run_for_instructions(1);
	state = _machine->get_processor_state();
	XCTAssert(state.address[0] == 0xfffffb2e, "A0 was %08x instead of 0xfffffb2e", state.address[0]);

	// Perform MOVEA.w (0x1000), A1
	_machine->run_for_instructions(1);
	state = _machine->get_processor_state();
	XCTAssert(state.address[1] == 0x0000303c, "A1 was %08x instead of 0x0000303c", state.address[1]);

	// Perform MOVE #$400, A4; MOVE.l (A4), D2
	_machine->run_for_instructions(2);
	state = _machine->get_processor_state();
	XCTAssert(state.address[4] == 0x1000, "A4 was %08x instead of 0x00001000", state.address[4]);
	XCTAssert(state.data[2] == 0x303cfb2e, "D2 was %08x instead of 0x303cfb2e", state.data[2]);
}

- (void)testVectoredInterrupt {
	_machine->set_program({
		0x46fc,	0x2000,		// MOVE.w #$2000, SR
		0x4e71,				// NOP
		0x4e71,				// NOP
		0x4e71,				// NOP
		0x4e71,				// NOP
		0x4e71,				// NOP
	});

	// Set the vector that will be supplied back to the start of the
	// program; this will ensure no further exceptions following
	// the interrupt.
	const auto vector = _machine->ram_at(40);
	vector[0] = 0x0000;
	vector[1] = 0x1004;

	_machine->run_for_instructions(3);
	_machine->processor().set_interrupt_level(1);
	_machine->run_for_instructions(1);

	const auto state = _machine->processor().get_state();
	XCTAssert(state.program_counter == 0x1008);	// i.e. the interrupt happened, the instruction performed was the one at 1004, and therefore
												// by the wonders of prefetch the program counter is now at 1008.
}

- (void)testOpcodeCoverage {
	// Perform an audit of implemented instructions.
	CPU::MC68000::ProcessorStorageTests storage_tests(
		_machine->processor(),
		[[NSBundle bundleForClass:[self class]] pathForResource:@"OPCLOGR2" ofType:@"BIN"].UTF8String
	);

	// This is a list of instructions nominated as valid with OPCLOGR2.BIN but with no obvious decoding —
	// the disassemblers I tried couldn't figure them out, and I didn't spot them anywhere in the PRM.
	NSSet<NSNumber *> *const undecodables = [NSSet setWithArray:@[
		// These look like malformed MOVEs.
		@(0x2e7d),	@(0x2e7e),	@(0x2e7f),	@(0x2efd),	@(0x2efe),	@(0x2eff),	@(0x2f7d),	@(0x2f7e),
		@(0x2f7f),	@(0x2fc0),	@(0x2fc1),	@(0x2fc2),	@(0x2fc3),	@(0x2fc4),	@(0x2fc5),	@(0x2fc6),
		@(0x2fc7),	@(0x2fc8),	@(0x2fc9),	@(0x2fca),	@(0x2fcb),	@(0x2fcc),	@(0x2fcd),	@(0x2fce),
		@(0x2fcf),	@(0x2fd0),	@(0x2fd1),	@(0x2fd2),	@(0x2fd3),	@(0x2fd4),	@(0x2fd5),	@(0x2fd6),
		@(0x2fd7),	@(0x2fd8),	@(0x2fd9),	@(0x2fda),	@(0x2fdb),	@(0x2fdc),	@(0x2fdd),	@(0x2fde),
		@(0x2fdf),	@(0x2fe0),	@(0x2fe1),	@(0x2fe2),	@(0x2fe3),	@(0x2fe4),	@(0x2fe5),	@(0x2fe6),
		@(0x2fe7),	@(0x2fe8),	@(0x2fe9),	@(0x2fea),	@(0x2feb),	@(0x2fec),	@(0x2fed),	@(0x2fee),
		@(0x2fef),	@(0x2ff0),	@(0x2ff1),	@(0x2ff2),	@(0x2ff3),	@(0x2ff4),	@(0x2ff5),	@(0x2ff6),
		@(0x2ff7),	@(0x2ff8),	@(0x2ff9),	@(0x2ffa),	@(0x2ffb),	@(0x2ffc),	@(0x2ffd),	@(0x2ffe),
		@(0x2fff),

		@(0x3e7d),	@(0x3e7e),	@(0x3e7f),	@(0x3efd),	@(0x3efe),	@(0x3eff),	@(0x3f7d),	@(0x3f7e),
		@(0x3f7f),	@(0x3fc0),	@(0x3fc1),	@(0x3fc2),	@(0x3fc3),	@(0x3fc4),	@(0x3fc5),	@(0x3fc6),
		@(0x3fc7),	@(0x3fc8),	@(0x3fc9),	@(0x3fca),	@(0x3fcb),	@(0x3fcc),	@(0x3fcd),	@(0x3fce),
		@(0x3fcf),	@(0x3fd0),	@(0x3fd1),	@(0x3fd2),	@(0x3fd3),	@(0x3fd4),	@(0x3fd5),	@(0x3fd6),
		@(0x3fd7),	@(0x3fd8),	@(0x3fd9),	@(0x3fda),	@(0x3fdb),	@(0x3fdc),	@(0x3fdd),	@(0x3fde),
		@(0x3fdf),	@(0x3fe0),	@(0x3fe1),	@(0x3fe2),	@(0x3fe3),	@(0x3fe4),	@(0x3fe5),	@(0x3fe6),
		@(0x3fe7),	@(0x3fe8),	@(0x3fe9),	@(0x3fea),	@(0x3feb),	@(0x3fec),	@(0x3fed),	@(0x3fee),
		@(0x3fef),	@(0x3ff0),	@(0x3ff1),	@(0x3ff2),	@(0x3ff3),	@(0x3ff4),	@(0x3ff5),	@(0x3ff6),
		@(0x3ff7),	@(0x3ff8),	@(0x3ff9),	@(0x3ffa),	@(0x3ffb),	@(0x3ffc),	@(0x3ffd),	@(0x3ffe),
		@(0x3fff),

		@(0x46c8),	@(0x46c9),	@(0x46ca),	@(0x46cb),	@(0x46cc),	@(0x46cd),	@(0x46ce),	@(0x46cf),
		@(0x46fd),	@(0x46fe),	@(0x46ff),	@(0x47c0),	@(0x47c1),	@(0x47c2),	@(0x47c3),	@(0x47c4),
		@(0x47c5),	@(0x47c6),	@(0x47c7),	@(0x47c8),	@(0x47c9),	@(0x47ca),	@(0x47cb),	@(0x47cc),
		@(0x47cd),	@(0x47ce),	@(0x47cf),	@(0x47d8),	@(0x47d9),	@(0x47da),	@(0x47db),	@(0x47dc),
		@(0x47dd),	@(0x47de),	@(0x47df),	@(0x47e0),	@(0x47e1),	@(0x47e2),	@(0x47e3),	@(0x47e4),
		@(0x47e5),	@(0x47e6),	@(0x47e7),	@(0x47fc),	@(0x47fd),	@(0x47fe),	@(0x47ff),	@(0x4e80),
		@(0x4e81),	@(0x4e82),	@(0x4e83),	@(0x4e84),	@(0x4e85),	@(0x4e86),	@(0x4e87),	@(0x4e88),
		@(0x4e89),	@(0x4e8a),	@(0x4e8b),	@(0x4e8c),	@(0x4e8d),	@(0x4e8e),	@(0x4e8f),	@(0x4e98),
		@(0x4e99),	@(0x4e9a),	@(0x4e9b),	@(0x4e9c),	@(0x4e9d),	@(0x4e9e),	@(0x4e9f),	@(0x4ea0),
		@(0x4ea1),	@(0x4ea2),	@(0x4ea3),	@(0x4ea4),	@(0x4ea5),	@(0x4ea6),	@(0x4ea7),	@(0x4ebc),
		@(0x4ebd),	@(0x4ebe),	@(0x4ebf),	@(0x4ec0),	@(0x4ec1),	@(0x4ec2),	@(0x4ec3),	@(0x4ec4),
		@(0x4ec5),	@(0x4ec6),	@(0x4ec7),	@(0x4ec8),	@(0x4ec9),	@(0x4eca),	@(0x4ecb),	@(0x4ecc),
		@(0x4ecd),	@(0x4ece),	@(0x4ecf),	@(0x4ed8),	@(0x4ed9),	@(0x4eda),	@(0x4edb),	@(0x4edc),
		@(0x4edd),	@(0x4ede),	@(0x4edf),	@(0x4ee0),	@(0x4ee1),	@(0x4ee2),	@(0x4ee3),	@(0x4ee4),
		@(0x4ee5),	@(0x4ee6),	@(0x4ee7),	@(0x4efc),	@(0x4efd),	@(0x4efe),	@(0x4eff),	@(0x4f88),
		@(0x4f89),	@(0x4f8a),	@(0x4f8b),	@(0x4f8c),	@(0x4f8d),	@(0x4f8e),	@(0x4f8f),	@(0x4fbd),
		@(0x4fbe),	@(0x4fbf),	@(0x4fc0),	@(0x4fc1),	@(0x4fc2),	@(0x4fc3),	@(0x4fc4),	@(0x4fc5),
		@(0x4fc6),	@(0x4fc7),	@(0x4fc8),	@(0x4fc9),	@(0x4fca),	@(0x4fcb),	@(0x4fcc),	@(0x4fcd),
		@(0x4fce),	@(0x4fcf),	@(0x4fd8),	@(0x4fd9),	@(0x4fda),	@(0x4fdb),	@(0x4fdc),	@(0x4fdd),
		@(0x4fde),	@(0x4fdf),	@(0x4fe0),	@(0x4fe1),	@(0x4fe2),	@(0x4fe3),	@(0x4fe4),	@(0x4fe5),
		@(0x4fe6),	@(0x4fe7),	@(0x4ffc),	@(0x4ffd),	@(0x4ffe),	@(0x4fff),

		@(0x50fa),	@(0x50fb),	@(0x50fc),	@(0x50fd),	@(0x50fe),	@(0x50ff),	@(0x51fa),	@(0x51fb),
		@(0x51fc),	@(0x51fd),	@(0x51fe),	@(0x51ff),	@(0x52fa),	@(0x52fb),	@(0x52fc),	@(0x52fd),
		@(0x52fe),	@(0x52ff),	@(0x53fa),	@(0x53fb),	@(0x53fc),	@(0x53fd),	@(0x53fe),	@(0x53ff),
		@(0x54fa),	@(0x54fb),	@(0x54fc),	@(0x54fd),	@(0x54fe),	@(0x54ff),	@(0x55fa),	@(0x55fb),
		@(0x55fc),	@(0x55fd),	@(0x55fe),	@(0x55ff),	@(0x56fa),	@(0x56fb),	@(0x56fc),	@(0x56fd),
		@(0x56fe),	@(0x56ff),	@(0x57fa),	@(0x57fb),	@(0x57fc),	@(0x57fd),	@(0x57fe),	@(0x57ff),
		@(0x58fa),	@(0x58fb),	@(0x58fc),	@(0x58fd),	@(0x58fe),	@(0x58ff),	@(0x59fa),	@(0x59fb),
		@(0x59fc),	@(0x59fd),	@(0x59fe),	@(0x59ff),	@(0x5afa),	@(0x5afb),	@(0x5afc),	@(0x5afd),
		@(0x5afe),	@(0x5aff),	@(0x5bfa),	@(0x5bfb),	@(0x5bfc),	@(0x5bfd),	@(0x5bfe),	@(0x5bff),
		@(0x5cfa),	@(0x5cfb),	@(0x5cfc),	@(0x5cfd),	@(0x5cfe),	@(0x5cff),	@(0x5dfa),	@(0x5dfb),
		@(0x5dfc),	@(0x5dfd),	@(0x5dfe),	@(0x5dff),	@(0x5eba),	@(0x5ebb),	@(0x5ebc),	@(0x5ebd),
		@(0x5ebe),	@(0x5ebf),	@(0x5efa),	@(0x5efb),	@(0x5efc),	@(0x5efd),	@(0x5efe),	@(0x5eff),
		@(0x5fba),	@(0x5fbb),	@(0x5fbc),	@(0x5fbd),	@(0x5fbe),	@(0x5fbf),	@(0x5ffa),	@(0x5ffb),
		@(0x5ffc),	@(0x5ffd),	@(0x5ffe),	@(0x5fff),

		// These are almost MOVEQs if only bit 8 weren't set.
		@(0x71c8),	@(0x71c9),	@(0x71ca),	@(0x71cb),	@(0x71cc),	@(0x71cd),	@(0x71ce),	@(0x71cf),
		@(0x71d8),	@(0x71d9),	@(0x71da),	@(0x71db),	@(0x71dc),	@(0x71dd),	@(0x71de),	@(0x71df),
		@(0x71e8),	@(0x71e9),	@(0x71ea),	@(0x71eb),	@(0x71ec),	@(0x71ed),	@(0x71ee),	@(0x71ef),
		@(0x71f8),	@(0x71f9),	@(0x71fa),	@(0x71fb),	@(0x71fc),	@(0x71fd),	@(0x71fe),	@(0x71ff),
		@(0x73c8),	@(0x73c9),	@(0x73ca),	@(0x73cb),	@(0x73cc),	@(0x73cd),	@(0x73ce),	@(0x73cf),
		@(0x73d8),	@(0x73d9),	@(0x73da),	@(0x73db),	@(0x73dc),	@(0x73dd),	@(0x73de),	@(0x73df),
		@(0x73e8),	@(0x73e9),	@(0x73ea),	@(0x73eb),	@(0x73ec),	@(0x73ed),	@(0x73ee),	@(0x73ef),
		@(0x73f8),	@(0x73f9),	@(0x73fa),	@(0x73fb),	@(0x73fc),	@(0x73fd),	@(0x73fe),	@(0x73ff),
		@(0x75c8),	@(0x75c9),	@(0x75ca),	@(0x75cb),	@(0x75cc),	@(0x75cd),	@(0x75ce),	@(0x75cf),
		@(0x75d8),	@(0x75d9),	@(0x75da),	@(0x75db),	@(0x75dc),	@(0x75dd),	@(0x75de),	@(0x75df),
		@(0x75e8),	@(0x75e9),	@(0x75ea),	@(0x75eb),	@(0x75ec),	@(0x75ed),	@(0x75ee),	@(0x75ef),
		@(0x75f8),	@(0x75f9),	@(0x75fa),	@(0x75fb),	@(0x75fc),	@(0x75fd),	@(0x75fe),	@(0x75ff),
		@(0x77c0),	@(0x77c1),	@(0x77c2),	@(0x77c3),	@(0x77c4),	@(0x77c5),	@(0x77c6),	@(0x77c7),
		@(0x77c8),	@(0x77c9),	@(0x77ca),	@(0x77cb),	@(0x77cc),	@(0x77cd),	@(0x77ce),	@(0x77cf),
		@(0x77d0),	@(0x77d1),	@(0x77d2),	@(0x77d3),	@(0x77d4),	@(0x77d5),	@(0x77d6),	@(0x77d7),
		@(0x77d8),	@(0x77d9),	@(0x77da),	@(0x77db),	@(0x77dc),	@(0x77dd),	@(0x77de),	@(0x77df),
		@(0x77e0),	@(0x77e1),	@(0x77e2),	@(0x77e3),	@(0x77e4),	@(0x77e5),	@(0x77e6),	@(0x77e7),
		@(0x77e8),	@(0x77e9),	@(0x77ea),	@(0x77eb),	@(0x77ec),	@(0x77ed),	@(0x77ee),	@(0x77ef),
		@(0x77f0),	@(0x77f1),	@(0x77f2),	@(0x77f3),	@(0x77f4),	@(0x77f5),	@(0x77f6),	@(0x77f7),
		@(0x77f8),	@(0x77f9),	@(0x77fa),	@(0x77fb),	@(0x77fc),	@(0x77fd),	@(0x77fe),	@(0x77ff),
		@(0x79c8),	@(0x79c9),	@(0x79ca),	@(0x79cb),	@(0x79cc),	@(0x79cd),	@(0x79ce),	@(0x79cf),
		@(0x79d8),	@(0x79d9),	@(0x79da),	@(0x79db),	@(0x79dc),	@(0x79dd),	@(0x79de),	@(0x79df),
		@(0x79e8),	@(0x79e9),	@(0x79ea),	@(0x79eb),	@(0x79ec),	@(0x79ed),	@(0x79ee),	@(0x79ef),
		@(0x79f8),	@(0x79f9),	@(0x79fa),	@(0x79fb),	@(0x79fc),	@(0x79fd),	@(0x79fe),	@(0x79ff),
		@(0x7bc8),	@(0x7bc9),	@(0x7bca),	@(0x7bcb),	@(0x7bcc),	@(0x7bcd),	@(0x7bce),	@(0x7bcf),
		@(0x7bd8),	@(0x7bd9),	@(0x7bda),	@(0x7bdb),	@(0x7bdc),	@(0x7bdd),	@(0x7bde),	@(0x7bdf),
		@(0x7be8),	@(0x7be9),	@(0x7bea),	@(0x7beb),	@(0x7bec),	@(0x7bed),	@(0x7bee),	@(0x7bef),
		@(0x7bf8),	@(0x7bf9),	@(0x7bfa),	@(0x7bfb),	@(0x7bfc),	@(0x7bfd),	@(0x7bfe),	@(0x7bff),
		@(0x7dc8),	@(0x7dc9),	@(0x7dca),	@(0x7dcb),	@(0x7dcc),	@(0x7dcd),	@(0x7dce),	@(0x7dcf),
		@(0x7dd8),	@(0x7dd9),	@(0x7dda),	@(0x7ddb),	@(0x7ddc),	@(0x7ddd),	@(0x7dde),	@(0x7ddf),
		@(0x7de8),	@(0x7de9),	@(0x7dea),	@(0x7deb),	@(0x7dec),	@(0x7ded),	@(0x7dee),	@(0x7def),
		@(0x7df8),	@(0x7df9),	@(0x7dfa),	@(0x7dfb),	@(0x7dfc),	@(0x7dfd),	@(0x7dfe),	@(0x7dff),
		@(0x7f40),	@(0x7f41),	@(0x7f42),	@(0x7f43),	@(0x7f44),	@(0x7f45),	@(0x7f46),	@(0x7f47),
		@(0x7f48),	@(0x7f49),	@(0x7f4a),	@(0x7f4b),	@(0x7f4c),	@(0x7f4d),	@(0x7f4e),	@(0x7f4f),
		@(0x7f50),	@(0x7f51),	@(0x7f52),	@(0x7f53),	@(0x7f54),	@(0x7f55),	@(0x7f56),	@(0x7f57),
		@(0x7f58),	@(0x7f59),	@(0x7f5a),	@(0x7f5b),	@(0x7f5c),	@(0x7f5d),	@(0x7f5e),	@(0x7f5f),
		@(0x7f60),	@(0x7f61),	@(0x7f62),	@(0x7f63),	@(0x7f64),	@(0x7f65),	@(0x7f66),	@(0x7f67),
		@(0x7f68),	@(0x7f69),	@(0x7f6a),	@(0x7f6b),	@(0x7f6c),	@(0x7f6d),	@(0x7f6e),	@(0x7f6f),
		@(0x7f70),	@(0x7f71),	@(0x7f72),	@(0x7f73),	@(0x7f74),	@(0x7f75),	@(0x7f76),	@(0x7f77),
		@(0x7f78),	@(0x7f79),	@(0x7f7a),	@(0x7f7b),	@(0x7f7c),	@(0x7f7d),	@(0x7f7e),	@(0x7f7f),
		@(0x7f80),	@(0x7f81),	@(0x7f82),	@(0x7f83),	@(0x7f84),	@(0x7f85),	@(0x7f86),	@(0x7f87),
		@(0x7f88),	@(0x7f89),	@(0x7f8a),	@(0x7f8b),	@(0x7f8c),	@(0x7f8d),	@(0x7f8e),	@(0x7f8f),
		@(0x7f90),	@(0x7f91),	@(0x7f92),	@(0x7f93),	@(0x7f94),	@(0x7f95),	@(0x7f96),	@(0x7f97),
		@(0x7f98),	@(0x7f99),	@(0x7f9a),	@(0x7f9b),	@(0x7f9c),	@(0x7f9d),	@(0x7f9e),	@(0x7f9f),
		@(0x7fa0),	@(0x7fa1),	@(0x7fa2),	@(0x7fa3),	@(0x7fa4),	@(0x7fa5),	@(0x7fa6),	@(0x7fa7),
		@(0x7fa8),	@(0x7fa9),	@(0x7faa),	@(0x7fab),	@(0x7fac),	@(0x7fad),	@(0x7fae),	@(0x7faf),
		@(0x7fb0),	@(0x7fb1),	@(0x7fb2),	@(0x7fb3),	@(0x7fb4),	@(0x7fb5),	@(0x7fb6),	@(0x7fb7),
		@(0x7fb8),	@(0x7fb9),	@(0x7fba),	@(0x7fbb),	@(0x7fbc),	@(0x7fbd),	@(0x7fbe),	@(0x7fbf),
		@(0x7fc0),	@(0x7fc1),	@(0x7fc2),	@(0x7fc3),	@(0x7fc4),	@(0x7fc5),	@(0x7fc6),	@(0x7fc7),
		@(0x7fc8),	@(0x7fc9),	@(0x7fca),	@(0x7fcb),	@(0x7fcc),	@(0x7fcd),	@(0x7fce),	@(0x7fcf),
		@(0x7fd0),	@(0x7fd1),	@(0x7fd2),	@(0x7fd3),	@(0x7fd4),	@(0x7fd5),	@(0x7fd6),	@(0x7fd7),
		@(0x7fd8),	@(0x7fd9),	@(0x7fda),	@(0x7fdb),	@(0x7fdc),	@(0x7fdd),	@(0x7fde),	@(0x7fdf),
		@(0x7fe0),	@(0x7fe1),	@(0x7fe2),	@(0x7fe3),	@(0x7fe4),	@(0x7fe5),	@(0x7fe6),	@(0x7fe7),
		@(0x7fe8),	@(0x7fe9),	@(0x7fea),	@(0x7feb),	@(0x7fec),	@(0x7fed),	@(0x7fee),	@(0x7fef),
		@(0x7ff0),	@(0x7ff1),	@(0x7ff2),	@(0x7ff3),	@(0x7ff4),	@(0x7ff5),	@(0x7ff6),	@(0x7ff7),
		@(0x7ff8),	@(0x7ff9),	@(0x7ffa),	@(0x7ffb),	@(0x7ffc),	@(0x7ffd),	@(0x7ffe),	@(0x7fff),

		@(0xbe7d),	@(0xbe7e),	@(0xbe7f),	@(0xbefd),	@(0xbefe),	@(0xbeff),	@(0xbf7a),	@(0xbf7b),
		@(0xbf7c),	@(0xbf7d),	@(0xbf7e),	@(0xbf7f),	@(0xbffd),	@(0xbffe),	@(0xbfff),

		//
		@(0xc6c8),	@(0xc6c9),	@(0xc6ca),	@(0xc6cb),	@(0xc6cc),	@(0xc6cd),	@(0xc6ce),	@(0xc6cf),
		@(0xc6fd),	@(0xc6fe),	@(0xc6ff),	@(0xc7c8),	@(0xc7c9),	@(0xc7ca),	@(0xc7cb),	@(0xc7cc),
		@(0xc7cd),	@(0xc7ce),	@(0xc7cf),	@(0xc7fd),	@(0xc7fe),	@(0xc7ff),	@(0xce88),	@(0xce89),
		@(0xce8a),	@(0xce8b),	@(0xce8c),	@(0xce8d),	@(0xce8e),	@(0xce8f),	@(0xcebd),	@(0xcebe),
		@(0xcebf),	@(0xcec8),	@(0xcec9),	@(0xceca),	@(0xcecb),	@(0xcecc),	@(0xcecd),	@(0xcece),
		@(0xcecf),	@(0xcefd),	@(0xcefe),	@(0xceff),	@(0xcf80),	@(0xcf81),	@(0xcf82),	@(0xcf83),
		@(0xcf84),	@(0xcf85),	@(0xcf86),	@(0xcf87),	@(0xcfba),	@(0xcfbb),	@(0xcfbc),	@(0xcfbd),
		@(0xcfbe),	@(0xcfbf),	@(0xcfc8),	@(0xcfc9),	@(0xcfca),	@(0xcfcb),	@(0xcfcc),	@(0xcfcd),
		@(0xcfce),	@(0xcfcf),	@(0xcffd),	@(0xcffe),	@(0xcfff),

		// These are from the Bcc/BRA/BSR page.
		@(0xd0fd),	@(0xd0fe),	@(0xd0ff),	@(0xd1fd),	@(0xd1fe),	@(0xd1ff),	@(0xd2fd),	@(0xd2fe),
		@(0xd2ff),	@(0xd3fd),	@(0xd3fe),	@(0xd3ff),	@(0xd4fd),	@(0xd4fe),	@(0xd4ff),	@(0xd5fd),
		@(0xd5fe),	@(0xd5ff),	@(0xd6fd),	@(0xd6fe),	@(0xd6ff),	@(0xd7fd),	@(0xd7fe),	@(0xd7ff),
		@(0xd8fd),	@(0xd8fe),	@(0xd8ff),	@(0xd9fd),	@(0xd9fe),	@(0xd9ff),	@(0xdafd),	@(0xdafe),
		@(0xdaff),	@(0xdbfd),	@(0xdbfe),	@(0xdbff),	@(0xdcfd),	@(0xdcfe),	@(0xdcff),	@(0xddfd),
		@(0xddfe),	@(0xddff),	@(0xdebd),	@(0xdebe),	@(0xdebf),	@(0xdefd),	@(0xdefe),	@(0xdeff),
		@(0xdfba),	@(0xdfbb),	@(0xdfbc),	@(0xdfbd),	@(0xdfbe),	@(0xdfbf),	@(0xdffd),	@(0xdffe),
		@(0xdfff),

		// The E line is for shifts and rolls; none of the those listed below appear to nominate valid
		// addressing modes.
		@(0xe6c0),	@(0xe6c1),	@(0xe6c2),	@(0xe6c3),	@(0xe6c4),	@(0xe6c5),	@(0xe6c6),	@(0xe6c7),
		@(0xe6c8),	@(0xe6c9),	@(0xe6ca),	@(0xe6cb),	@(0xe6cc),	@(0xe6cd),	@(0xe6ce),	@(0xe6cf),
		@(0xe6fa),	@(0xe6fb),	@(0xe6fc),	@(0xe6fd),	@(0xe6fe),	@(0xe6ff),	@(0xe7c0),	@(0xe7c1),
		@(0xe7c2),	@(0xe7c3),	@(0xe7c4),	@(0xe7c5),	@(0xe7c6),	@(0xe7c7),	@(0xe7c8),	@(0xe7c9),
		@(0xe7ca),	@(0xe7cb),	@(0xe7cc),	@(0xe7cd),	@(0xe7ce),	@(0xe7cf),	@(0xe7fa),	@(0xe7fb),
		@(0xe7fc),	@(0xe7fd),	@(0xe7fe),	@(0xe7ff),	@(0xeec0),	@(0xeec1),	@(0xeec2),	@(0xeec3),
		@(0xeec4),	@(0xeec5),	@(0xeec6),	@(0xeec7),	@(0xeec8),	@(0xeec9),	@(0xeeca),	@(0xeecb),
		@(0xeecc),	@(0xeecd),	@(0xeece),	@(0xeecf),	@(0xeed0),	@(0xeed1),	@(0xeed2),	@(0xeed3),
		@(0xeed4),	@(0xeed5),	@(0xeed6),	@(0xeed7),	@(0xeed8),	@(0xeed9),	@(0xeeda),	@(0xeedb),
		@(0xeedc),	@(0xeedd),	@(0xeede),	@(0xeedf),	@(0xeee0),	@(0xeee1),	@(0xeee2),	@(0xeee3),
		@(0xeee4),	@(0xeee5),	@(0xeee6),	@(0xeee7),	@(0xeee8),	@(0xeee9),	@(0xeeea),	@(0xeeeb),
		@(0xeeec),	@(0xeeed),	@(0xeeee),	@(0xeeef),	@(0xeef0),	@(0xeef1),	@(0xeef2),	@(0xeef3),
		@(0xeef4),	@(0xeef5),	@(0xeef6),	@(0xeef7),	@(0xeef8),	@(0xeef9),	@(0xeefa),	@(0xeefb),
		@(0xeefc),	@(0xeefd),	@(0xeefe),	@(0xeeff),	@(0xefc0),	@(0xefc1),	@(0xefc2),	@(0xefc3),
		@(0xefc4),	@(0xefc5),	@(0xefc6),	@(0xefc7),	@(0xefc8),	@(0xefc9),	@(0xefca),	@(0xefcb),
		@(0xefcc),	@(0xefcd),	@(0xefce),	@(0xefcf),	@(0xefd0),	@(0xefd1),	@(0xefd2),	@(0xefd3),
		@(0xefd4),	@(0xefd5),	@(0xefd6),	@(0xefd7),	@(0xefd8),	@(0xefd9),	@(0xefda),	@(0xefdb),
		@(0xefdc),	@(0xefdd),	@(0xefde),	@(0xefdf),	@(0xefe0),	@(0xefe1),	@(0xefe2),	@(0xefe3),
		@(0xefe4),	@(0xefe5),	@(0xefe6),	@(0xefe7),	@(0xefe8),	@(0xefe9),	@(0xefea),	@(0xefeb),
		@(0xefec),	@(0xefed),	@(0xefee),	@(0xefef),	@(0xeff0),	@(0xeff1),	@(0xeff2),	@(0xeff3),
		@(0xeff4),	@(0xeff5),	@(0xeff6),	@(0xeff7),	@(0xeff8),	@(0xeff9),	@(0xeffa),	@(0xeffb),
		@(0xeffc),	@(0xeffd),	@(0xeffe),	@(0xefff)
	]];

	NSSet<NSNumber *> *const falseValids = storage_tests.false_valids();
	NSSet<NSNumber *> *const falseInvalids = storage_tests.false_invalids();

	XCTAssert(!falseValids.count, "%@ opcodes should be invalid but aren't: %@", @(falseValids.count), falseValids.hexDump);

	NSMutableSet<NSNumber *> *const decodedUndecodables = [undecodables mutableCopy];
	[decodedUndecodables minusSet:falseInvalids];
	XCTAssert(!decodedUndecodables.count, "This test considers these undecodable but they were decoded: %@", decodedUndecodables.hexDump);

	NSMutableSet<NSNumber *> *const trimmedInvalids = [falseInvalids mutableCopy];
	[trimmedInvalids minusSet:undecodables];
	XCTAssert(!trimmedInvalids.count, "%@ opcodes should be valid but aren't: %@", @(trimmedInvalids.count), trimmedInvalids.hexDump);

//	XCTAssert(!falseInvalids.count, "%@ opcodes should be valid but aren't: %@", @(falseInvalids.count), falseInvalids.hexDump);
}

// MARK: - Portable 68k tests (mostly)

// Tests below this line were overwhelmingly ported from those of the Portable 68k
// package. That emulator does not include a licence. It reports that all tests were
// verified against an Amiga.
//
// Cf. https://sourceforge.net/projects/portable68000/


// MARK: ASL

- (void)testASLb_Dn_2 {
	_machine->set_program({
		0xe521		// ASL.B D2, D1
	});
	auto state = _machine->get_processor_state();
	state.data[1] = 0xce3dd567;
	state.data[2] = 2;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0xce3dd59c);
	XCTAssertEqual(state.data[2], 2);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend | Flag::Negative | Flag::Overflow | Flag::Carry);
	XCTAssertEqual(10, _machine->get_cycle_count());
}

- (void)testASLb_Dn_105 {
	_machine->set_program({
		0xe521		// ASL.B D2, D1
	});
	auto state = _machine->get_processor_state();
	state.data[1] = 0xce3dd567;
	state.data[2] = 105;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0xce3dd500);
	XCTAssertEqual(state.data[2], 105);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Overflow | Flag::Zero);
	XCTAssertEqual(88, _machine->get_cycle_count());
}

- (void)testASLw_Dn_0 {
	_machine->set_program({
		0xe561		// ASL.w D2, D1
	});
	auto state = _machine->get_processor_state();
	state.data[1] = 0xce3dd567;
	state.data[2] = 0;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0xce3dd567);
	XCTAssertEqual(state.data[2], 0);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Negative);
	XCTAssertEqual(6, _machine->get_cycle_count());
}

- (void)testASLw_Dn_0b {
	_machine->set_program({
		0xe561		// ASL.w D2, D1
	});
	auto state = _machine->get_processor_state();
	state.data[1] = 0xce3dd567;
	state.data[2] = 0xb;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0xce3d3800);
	XCTAssertEqual(state.data[2], 0xb);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend | Flag::Overflow | Flag::Carry);
	XCTAssertEqual(28, _machine->get_cycle_count());
}

- (void)testASLl_Dn {
	_machine->set_program({
		0xe5a1		// ASL.l D2, D1
	});
	auto state = _machine->get_processor_state();
	state.data[1] = 0xce3dd567;
	state.data[2] = 0x20;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0);
	XCTAssertEqual(state.data[2], 0x20);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend | Flag::Overflow | Flag::Carry | Flag::Zero);
	XCTAssertEqual(72, _machine->get_cycle_count());
}

- (void)testASLl_Imm {
	_machine->set_program({
		0xe181		// ASL.l #8, D1
	});
	auto state = _machine->get_processor_state();
	state.data[1] = 0xce3dd567;
	state.data[2] = 0x20;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0x3dd56700);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Overflow);
	XCTAssertEqual(24, _machine->get_cycle_count());
}

- (void)testASLw_XXXw_8ccc {
	_machine->set_program({
		0xe1f8, 0x3000		// ASL ($3000).w
	});
	*_machine->ram_at(0x3000) = 0x8ccc;

	_machine->run_for_instructions(1);

	const auto state = _machine->get_processor_state();
	XCTAssertEqual(*_machine->ram_at(0x3000), 0x1998);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Overflow | Flag::Extend | Flag::Carry);
	XCTAssertEqual(16, _machine->get_cycle_count());
}

- (void)testASLw_XXXw_45780782 {
	_machine->set_program({
		0xe1f8, 0x3000		// ASL ($3000).w
	});
	*_machine->ram_at(0x3000) = 0x4578;
	*_machine->ram_at(0x3002) = 0x0782;

	_machine->run_for_instructions(1);

	const auto state = _machine->get_processor_state();
	XCTAssertEqual(*_machine->ram_at(0x3000), 0x8af0);
	XCTAssertEqual(*_machine->ram_at(0x3002), 0x0782);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Overflow | Flag::Negative);
	XCTAssertEqual(16, _machine->get_cycle_count());
}

// MARK: ASR

- (void)testASRb_Dn_2 {
	_machine->set_program({
		0xe421		// ASR.B D2, D1
	});
	auto state = _machine->get_processor_state();
	state.data[1] = 0xce3dd567;
	state.data[2] = 2;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0xce3dd519);
	XCTAssertEqual(state.data[2], 2);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend | Flag::Carry);
	XCTAssertEqual(10, _machine->get_cycle_count());
}

- (void)testASRb_Dn_105 {
	_machine->set_program({
		0xe421		// ASR.B D2, D1
	});
	auto state = _machine->get_processor_state();
	state.data[1] = 0xce3dd567;
	state.data[2] = 105;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0xce3dd500);
	XCTAssertEqual(state.data[2], 105);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Zero);
	XCTAssertEqual(88, _machine->get_cycle_count());
}

- (void)testASRw_Dn_0 {
	_machine->set_program({
		0xe461		// ASR.w D2, D1
	});
	auto state = _machine->get_processor_state();
	state.data[1] = 0xce3dd567;
	state.data[2] = 0;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0xce3dd567);
	XCTAssertEqual(state.data[2], 0);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Negative);
	XCTAssertEqual(6, _machine->get_cycle_count());
}

- (void)testASRw_Dn_0b {
	_machine->set_program({
		0xe461		// ASR.w D2, D1
	});
	auto state = _machine->get_processor_state();
	state.data[1] = 0xce3dd567;
	state.data[2] = 0xb;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0xce3dfffa);
	XCTAssertEqual(state.data[2], 0xb);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend | Flag::Negative | Flag::Carry);
	XCTAssertEqual(28, _machine->get_cycle_count());
}

- (void)testASRl_Dn {
	_machine->set_program({
		0xe4a1		// ASR.l D2, D1
	});
	auto state = _machine->get_processor_state();
	state.data[1] = 0xce3dd567;
	state.data[2] = 0x20;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0xffffffff);
	XCTAssertEqual(state.data[2], 0x20);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend | Flag::Negative | Flag::Carry);
	XCTAssertEqual(72, _machine->get_cycle_count());
}

- (void)testASRl_Imm {
	_machine->set_program({
		0xe081		// ASR.l #8, D1
	});
	auto state = _machine->get_processor_state();
	state.data[1] = 0xce3dd567;
	state.data[2] = 0x20;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0xffce3dd5);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Negative);
	XCTAssertEqual(24, _machine->get_cycle_count());
}

- (void)testASRw_XXXw_8ccc {
	_machine->set_program({
		0xe0f8, 0x3000		// ASR ($3000).w
	});
	*_machine->ram_at(0x3000) = 0x8ccc;

	_machine->run_for_instructions(1);

	const auto state = _machine->get_processor_state();
	XCTAssertEqual(*_machine->ram_at(0x3000), 0xc666);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Negative);
	XCTAssertEqual(16, _machine->get_cycle_count());
}

- (void)testASRw_XXXw_45780782 {
	_machine->set_program({
		0xe0f8, 0x3000		// ASR ($3000).w
	});
	*_machine->ram_at(0x3000) = 0x8578;
	*_machine->ram_at(0x3002) = 0x0782;

	_machine->run_for_instructions(1);

	const auto state = _machine->get_processor_state();
	XCTAssertEqual(*_machine->ram_at(0x3000), 0xc2bc);
	XCTAssertEqual(*_machine->ram_at(0x3002), 0x0782);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Negative);
	XCTAssertEqual(16, _machine->get_cycle_count());
}

// MARK: CLR

- (void)testCLRw {
	_machine->set_program({
		0x4244		// CLR.w D4
	});
	auto state = _machine->get_processor_state();
	state.data[4] = 0x9853abcd;
	state.status |= Flag::Extend | Flag::Negative | Flag::Overflow | Flag::Carry;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[4], 0x98530000);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend | Flag::Zero);
	XCTAssertEqual(4, _machine->get_cycle_count());
}

- (void)testCLRl_Dn {
	_machine->set_program({
		0x4284		// CLR.l D4
	});
	auto state = _machine->get_processor_state();
	state.data[4] = 0x9853abcd;
	state.status |= Flag::Extend | Flag::Negative | Flag::Overflow | Flag::Carry;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[4], 0x0);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend | Flag::Zero);
	XCTAssertEqual(6, _machine->get_cycle_count());
}

- (void)testCLRl_XXXl {
	_machine->set_program({
		0x42b9, 0x0001, 0x86a0		// CLR.l ($186a0).l
	});
	*_machine->ram_at(0x186a0) = 0x9853;
	*_machine->ram_at(0x186a2) = 0xabcd;
	auto state = _machine->get_processor_state();
	state.status |= Flag::Extend | Flag::Negative | Flag::Overflow | Flag::Carry;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(*_machine->ram_at(0x186a0), 0x0);
	XCTAssertEqual(*_machine->ram_at(0x186a2), 0x0);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend | Flag::Zero);
	XCTAssertEqual(28, _machine->get_cycle_count());
}

- (void)testCLRb_XXXl {
	_machine->set_program({
		0x4239, 0x0001, 0x86a0		// CLR.b ($186a0).l
	});
	*_machine->ram_at(0x186a0) = 0x9853;
	*_machine->ram_at(0x186a2) = 0xabcd;
	auto state = _machine->get_processor_state();
	state.status |= Flag::Extend | Flag::Negative | Flag::Overflow | Flag::Carry;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(*_machine->ram_at(0x186a0), 0x0053);
	XCTAssertEqual(*_machine->ram_at(0x186a2), 0xabcd);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend | Flag::Zero);
	XCTAssertEqual(20, _machine->get_cycle_count());
}

// MARK: EXG

- (void)testEXG_D1D2 {
	_machine->set_program({
		0xc342		// EXG D1, D2
	});

	auto state = _machine->get_processor_state();
	state.data[1] = 0x11111111;
	state.data[2] = 0x22222222;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0x22222222);
	XCTAssertEqual(state.data[2], 0x11111111);
	XCTAssertEqual(6, _machine->get_cycle_count());
}

- (void)testEXG_A1A2 {
	_machine->set_program({
		0xc34a		// EXG A1, A2
	});

	auto state = _machine->get_processor_state();
	state.address[1] = 0x11111111;
	state.address[2] = 0x22222222;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.address[1], 0x22222222);
	XCTAssertEqual(state.address[2], 0x11111111);
	XCTAssertEqual(6, _machine->get_cycle_count());
}

- (void)testEXG_A1D1 {
	_machine->set_program({
		0xc389		// EXG A1, D1
	});

	auto state = _machine->get_processor_state();
	state.data[1] = 0x11111111;
	state.address[1] = 0x22222222;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0x22222222);
	XCTAssertEqual(state.address[1], 0x11111111);
	XCTAssertEqual(6, _machine->get_cycle_count());
}

// MARK: EXT

- (void)performEXTwd3:(uint32_t)d3 {
	_machine->set_program({
		0x4883		// EXT.W D3
	});

	auto state = _machine->get_processor_state();
	state.data[3] = d3;
	state.status = 0x13;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	XCTAssertEqual(4, _machine->get_cycle_count());
}

- (void)testEXTw_78 {
	[self performEXTwd3:0x12345678];

	const auto state = _machine->get_processor_state();
	XCTAssertEqual(state.data[3], 0x12340078);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend);
}

- (void)testEXTw_00 {
	[self performEXTwd3:0x12345600];

	const auto state = _machine->get_processor_state();
	XCTAssertEqual(state.data[3], 0x12340000);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend | Flag::Zero);
}

- (void)testEXTw_f0 {
	[self performEXTwd3:0x123456f0];

	const auto state = _machine->get_processor_state();
	XCTAssertEqual(state.data[3], 0x1234fff0);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend | Flag::Negative);
}

- (void)testEXTl {
	_machine->set_program({
		0x48c3		// EXT.L D3
	});

	auto state = _machine->get_processor_state();
	state.data[3] = 0x1234f6f0;
	state.status = 0x13;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	XCTAssertEqual(4, _machine->get_cycle_count());

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[3], 0xfffff6f0);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend | Flag::Negative);
}

// MARK: LEA

- (void)testLEA_w {
	_machine->set_program({
		0x41f8, 0x000c		// LEA ($12).w, A0
	});

	_machine->run_for_instructions(1);

	const auto state = _machine->get_processor_state();
	XCTAssertEqual(state.address[0], 0xc);
	XCTAssertEqual(8, _machine->get_cycle_count());
}

- (void)testLEA_l {
	_machine->set_program({
		0x41f9, 0x000c, 0x000d		// LEA ($c000d).w, A0
	});

	_machine->run_for_instructions(1);

	const auto state = _machine->get_processor_state();
	XCTAssertEqual(state.address[0], 0xc000d);
	XCTAssertEqual(12, _machine->get_cycle_count());
}

- (void)testLEA_An {
	_machine->set_program({
		0x43d2,		// LEA (A2), A1
	});

	auto state = _machine->get_processor_state();
	state.address[2] = 0xc000d;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.address[1], 0xc000d);
	XCTAssertEqual(state.address[2], 0xc000d);
	XCTAssertEqual(4, _machine->get_cycle_count());
}

- (void)testLEA_dAn {
	_machine->set_program({
		0x43ea, 0xffff		// LEA (-1,A2), A1
	});

	auto state = _machine->get_processor_state();
	state.address[2] = 0xc000d;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.address[1], 0xc000c);
	XCTAssertEqual(state.address[2], 0xc000d);
	XCTAssertEqual(8, _machine->get_cycle_count());
}

- (void)testLEA_dAnDnw {
	_machine->set_program({
		0x43f2, 0x7002		// LEA (2,A2,D7.W), A1
	});

	auto state = _machine->get_processor_state();
	state.address[2] = 0xc000d;
	state.data[7] = 0x10000022;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.address[1], 0xc0031);
	XCTAssertEqual(state.address[2], 0xc000d);
	XCTAssertEqual(state.data[7], 0x10000022);
	XCTAssertEqual(12, _machine->get_cycle_count());
}

- (void)testLEA_dAnDnl {
	_machine->set_program({
		0x43f2, 0x7802		// LEA (2,A2,D7.l), A1
	});

	auto state = _machine->get_processor_state();
	state.address[2] = 0xc000d;
	state.data[7] = 0x10000022;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.address[1], 0x100c0031);
	XCTAssertEqual(state.address[2], 0xc000d);
	XCTAssertEqual(state.data[7], 0x10000022);
	XCTAssertEqual(12, _machine->get_cycle_count());
}

- (void)testLEA_dPC {
	_machine->set_program({
		0x43fa, 0xeff8		// LEA	(-6,PC), A1
	});

	auto state = _machine->get_processor_state();
	state.address[2] = 0xc000d;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.address[1], 0xFFFFFFFA);
	XCTAssertEqual(8, _machine->get_cycle_count());
}

- (void)testLEA_dPCDn {
	_machine->set_program({
		0x43fb, 0x30fe		// LEA (-6,PC,D3), A1
	});

	auto state = _machine->get_processor_state();
	state.data[3] = 0x2;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.address[1], 0x1002);
	XCTAssertEqual(state.data[3], 0x2);
	XCTAssertEqual(12, _machine->get_cycle_count());
}

// MARK: LINK

- (void)testLINKA1_5 {
	_machine->set_program({
		0x4e51, 0x0005		// LINK a1, #5
	});
	auto state = _machine->get_processor_state();
	state.address[1] = 0x11111111;
	_machine->set_initial_stack_pointer(0x22222222);

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.address[1], 0x2222221e);
	XCTAssertEqual(state.supervisor_stack_pointer, 0x22222223);
	XCTAssertEqual(*_machine->ram_at(0x2222221e), 0x1111);
	XCTAssertEqual(*_machine->ram_at(0x22222220), 0x1111);
	XCTAssertEqual(16, _machine->get_cycle_count());
}

- (void)testLINKA7_5 {
	_machine->set_program({
		0x4e57, 0x0005		// LINK a7, #5
	});
	_machine->set_initial_stack_pointer(0x22222222);

	_machine->run_for_instructions(1);

	const auto state = _machine->get_processor_state();
	XCTAssertEqual(state.supervisor_stack_pointer, 0x22222223);
	XCTAssertEqual(*_machine->ram_at(0x2222221e), 0x2222);
	XCTAssertEqual(*_machine->ram_at(0x22222220), 0x221e);
	XCTAssertEqual(16, _machine->get_cycle_count());
}

- (void)testLINKA1_8000 {
	_machine->set_program({
		0x4e51, 0x8000		// LINK a1, #$8000
	});
	auto state = _machine->get_processor_state();
	state.address[1] = 0x11111111;
	_machine->set_initial_stack_pointer(0x22222222);

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.address[1], 0x2222221e);
	XCTAssertEqual(state.supervisor_stack_pointer, 0x2221a21e);
	XCTAssertEqual(*_machine->ram_at(0x2222221e), 0x1111);
	XCTAssertEqual(*_machine->ram_at(0x22222220), 0x1111);
	XCTAssertEqual(16, _machine->get_cycle_count());
}

// MARK: LSL

- (void)testLSLb_Dn_2 {
	_machine->set_program({
		0xe529		// LSL.b D2, D1
	});
	auto state = _machine->get_processor_state();
	state.data[1] = 0xce3dd567;
	state.data[2] = 2;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0xce3dd59c);
	XCTAssertEqual(state.data[2], 2);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend | Flag::Negative | Flag::Carry);
	XCTAssertEqual(10, _machine->get_cycle_count());
}

- (void)testLSLb_Dn_69 {
	_machine->set_program({
		0xe529		// LSL.b D2, D1
	});
	auto state = _machine->get_processor_state();
	state.data[1] = 0xce3dd567;
	state.data[2] = 0x69;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0xce3dd500);
	XCTAssertEqual(state.data[2], 0x69);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Zero);
	XCTAssertEqual(88, _machine->get_cycle_count());
}

- (void)testLSLw_Dn_0 {
	_machine->set_program({
		0xe569		// LSL.w D2, D1
	});
	auto state = _machine->get_processor_state();
	state.data[1] = 0xce3dd567;
	state.data[2] = 0;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0xce3dd567);
	XCTAssertEqual(state.data[2], 0);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Negative);
	XCTAssertEqual(6, _machine->get_cycle_count());
}

- (void)testLSLw_Dn_b {
	_machine->set_program({
		0xe569		// LSL.w D2, D1
	});
	auto state = _machine->get_processor_state();
	state.data[1] = 0xce3dd567;
	state.data[2] = 0xb;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0xce3d3800);
	XCTAssertEqual(state.data[2], 0xb);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend | Flag::Carry);
	XCTAssertEqual(28, _machine->get_cycle_count());
}

- (void)testLSLl_Dn {
	_machine->set_program({
		0xe5a9		// LSL.l D2, D1
	});
	auto state = _machine->get_processor_state();
	state.data[1] = 0xce3dd567;
	state.data[2] = 0x20;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0);
	XCTAssertEqual(state.data[2], 0x20);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend | Flag::Carry | Flag::Zero);
	XCTAssertEqual(72, _machine->get_cycle_count());
}

- (void)testLSLl_Imm {
	_machine->set_program({
		0xe189		// LSL.l #8, D1
	});
	auto state = _machine->get_processor_state();
	state.data[1] = 0xce3dd567;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0x3dd56700);
	XCTAssertEqual(state.status & Flag::ConditionCodes, 0);
	XCTAssertEqual(24, _machine->get_cycle_count());
}

- (void)testLSL_XXXw {
	_machine->set_program({
		0xe3f8, 0x3000		// LSL.l ($3000).w
	});
	*_machine->ram_at(0x3000) = 0x8ccc;

	_machine->run_for_instructions(1);

	const auto state = _machine->get_processor_state();
	XCTAssertEqual(*_machine->ram_at(0x3000), 0x1998);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Carry | Flag::Extend);
	XCTAssertEqual(16, _machine->get_cycle_count());
}

// MARK: LSR

- (void)testLSRb_Dn_2 {
	_machine->set_program({
		0xe429		// LSR.b D2, D1
	});
	auto state = _machine->get_processor_state();
	state.data[1] = 0xce3dd567;
	state.data[2] = 2;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0xce3dd519);
	XCTAssertEqual(state.data[2], 2);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend | Flag::Carry);
	XCTAssertEqual(10, _machine->get_cycle_count());
}

- (void)testLSRb_Dn_69 {
	_machine->set_program({
		0xe429		// LSR.b D2, D1
	});
	auto state = _machine->get_processor_state();
	state.data[1] = 0xce3dd567;
	state.data[2] = 0x69;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0xce3dd500);
	XCTAssertEqual(state.data[2], 0x69);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Zero);
	XCTAssertEqual(88, _machine->get_cycle_count());
}

- (void)testLSRw_Dn_0 {
	_machine->set_program({
		0xe469		// LSR.w D2, D1
	});
	auto state = _machine->get_processor_state();
	state.data[1] = 0xce3dd567;
	state.data[2] = 0;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0xce3dd567);
	XCTAssertEqual(state.data[2], 0);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Negative);
	XCTAssertEqual(6, _machine->get_cycle_count());
}

- (void)testLSRw_Dn_b {
	_machine->set_program({
		0xe469		// LSR.w D2, D1
	});
	auto state = _machine->get_processor_state();
	state.data[1] = 0xce3dd567;
	state.data[2] = 0xb;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0xce3d001a);
	XCTAssertEqual(state.data[2], 0xb);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend | Flag::Carry);
	XCTAssertEqual(28, _machine->get_cycle_count());
}

- (void)testLSRl_Dn {
	_machine->set_program({
		0xe4a9		// LSR.l D2, D1
	});
	auto state = _machine->get_processor_state();
	state.data[1] = 0xce3dd567;
	state.data[2] = 0x20;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0);
	XCTAssertEqual(state.data[2], 0x20);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend | Flag::Carry | Flag::Zero);
	XCTAssertEqual(72, _machine->get_cycle_count());
}

- (void)testLSRl_Imm {
	_machine->set_program({
		0xe089		// LSR.L #8, D1
	});
	auto state = _machine->get_processor_state();
	state.data[1] = 0xce3dd567;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0xce3dd5);
	XCTAssertEqual(state.status & Flag::ConditionCodes, 0);
	XCTAssertEqual(24, _machine->get_cycle_count());
}

- (void)testLSR_XXXw {
	_machine->set_program({
		0xe2f8, 0x3000		// LSR.l ($3000).w
	});
	*_machine->ram_at(0x3000) = 0x8ccc;

	_machine->run_for_instructions(1);

	const auto state = _machine->get_processor_state();
	XCTAssertEqual(*_machine->ram_at(0x3000), 0x4666);
	XCTAssertEqual(state.status & Flag::ConditionCodes, 0);
	XCTAssertEqual(16, _machine->get_cycle_count());
}

// MARK: MOVEM

- (void)testMOVEMl_fromD0D1 {
	_machine->set_program({
		0x48e1, 0xc000		// MOVEM.L D0-D1, -(A1)
	});
	auto state = _machine->get_processor_state();
	state.address[1] = 0x3000;
	state.data[0] = 0x12345678;
	state.data[1] = 0x87654321;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.address[1], 0x2ff8);
	XCTAssertEqual(state.data[0], 0x12345678);
	XCTAssertEqual(state.data[1], 0x87654321);
	XCTAssertEqual(*_machine->ram_at(0x2ff8), 0x1234);
	XCTAssertEqual(*_machine->ram_at(0x2ffa), 0x5678);
	XCTAssertEqual(*_machine->ram_at(0x2ffc), 0x8765);
	XCTAssertEqual(*_machine->ram_at(0x2ffe), 0x4321);
	XCTAssertEqual(24, _machine->get_cycle_count());
}

- (void)testMOVEMl_fromD0D1A1 {
	_machine->set_program({
		0x48e1, 0xc040		// MOVEM.L D0-D1/A1, -(A1)
	});
	auto state = _machine->get_processor_state();
	state.address[1] = 0x3000;
	state.data[0] = 0x12345678;
	state.data[1] = 0x87654321;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.address[1], 0x2ff4);
	XCTAssertEqual(state.data[0], 0x12345678);
	XCTAssertEqual(state.data[1], 0x87654321);
	XCTAssertEqual(*_machine->ram_at(0x2ff4), 0x1234);
	XCTAssertEqual(*_machine->ram_at(0x2ff6), 0x5678);
	XCTAssertEqual(*_machine->ram_at(0x2ff8), 0x8765);
	XCTAssertEqual(*_machine->ram_at(0x2ffa), 0x4321);
	XCTAssertEqual(*_machine->ram_at(0x2ffc), 0x0000);
	XCTAssertEqual(*_machine->ram_at(0x2ffe), 0x3000);
	XCTAssertEqual(32, _machine->get_cycle_count());
}

- (void)testMOVEMl_fromEverything {
	_machine->set_program({
		0x48e4, 0xffff		// MOVEM.L D0-D7/A0-A7, -(A4)
	});
	auto state = _machine->get_processor_state();
	for(int c = 0; c < 8; ++c)
		state.data[c] = (c+1) * 0x11111111;
	for(int c = 0; c < 7; ++c)
		state.address[c] = ((c < 4) ? (c + 9) : (c + 8)) * 0x11111111;
	state.address[4] = 0x4000;
	_machine->set_initial_stack_pointer(0xffffffff);

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.address[4], 0x3fc0);

	const uint32_t expected_values[] = {
		0xffffffff, 0xeeeeeeee, 0xdddddddd, 0x00004000,
		0xcccccccc, 0xbbbbbbbb, 0xaaaaaaaa, 0x99999999,
		0x88888888, 0x77777777, 0x66666666, 0x55555555,
		0x44444444, 0x33333333, 0x22222222, 0x11111111,
	};
	const uint32_t *expected_value = expected_values;
	for(uint32_t address = 0x3ffc; address <= 0x3fc0; address += 4) {
		XCTAssertEqual(*_machine->ram_at(address), (*expected_value >> 16));
		XCTAssertEqual(*_machine->ram_at(address + 2), (*expected_value & 0xffff));
		++expected_value;
	}

	XCTAssertEqual(136, _machine->get_cycle_count());
}

- (void)testMOVEMw_fromD4 {
	_machine->set_program({
		0x48a4, 0x0800		// MOVEM.W D4, -(A4)
	});
	auto state = _machine->get_processor_state();
	state.address[4] = 0x4000;
	state.data[4] = 0x111a1111;
	state.data[0] = 0xffffffff;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();

	XCTAssertEqual(state.address[4], 0x3ffe);
	XCTAssertEqual(state.data[0], 0xffffffff);
	XCTAssertEqual(state.data[4], 0x111a1111);

	XCTAssertEqual(*_machine->ram_at(0x3ffe), 0x1111);
	XCTAssertEqual(*_machine->ram_at(0x3ffc), 0x0000);

	XCTAssertEqual(12, _machine->get_cycle_count());
}

// TODO: port MOVEM.W D4/D0, -(A4), which tests bus error response.

- (void)testMOVEMl_toD1D2A1A2 {
	_machine->set_program({
		0x4cd9, 0x0606		// MOVEM.l (A1)+, D1-D2/A1-A2
	});
	auto state = _machine->get_processor_state();
	state.address[1] = 0x4000;
	*_machine->ram_at(0x4000) = 0x1111;
	*_machine->ram_at(0x4002) = 0x1111;
	*_machine->ram_at(0x4004) = 0x2222;
	*_machine->ram_at(0x4006) = 0x2222;
	*_machine->ram_at(0x400c) = 0x3333;
	*_machine->ram_at(0x400e) = 0x3333;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();

	XCTAssertEqual(state.data[1], 0x11111111);
	XCTAssertEqual(state.data[2], 0x22222222);
	XCTAssertEqual(state.address[1], 0x4010);
	XCTAssertEqual(state.address[2], 0x33333333);

	XCTAssertEqual(44, _machine->get_cycle_count());
}

- (void)testMOVEMw_signExtend {
	_machine->set_program({
		0x4c99, 0x0002		// MOVEM.w (A1)+, D1
	});
	auto state = _machine->get_processor_state();
	state.address[1] = 0x4000;
	*_machine->ram_at(0x4000) = 0x8000;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();

	XCTAssertEqual(state.data[1], 0xffff8000);
	XCTAssertEqual(state.address[1], 0x4002);

	XCTAssertEqual(16, _machine->get_cycle_count());
}

- (void)testMOVEMw_fromIndirect {
	_machine->set_program({
		0x4c91, 0x0206		// MOVEM.w (A1), A1/D1-D2
	});
	auto state = _machine->get_processor_state();
	state.address[1] = 0x4000;
	state.data[2] = 0xffffffff;
	*_machine->ram_at(0x4000) = 0x8000;
	*_machine->ram_at(0x4002) = 0x2222;
	*_machine->ram_at(0x4004) = 0x3333;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();

	XCTAssertEqual(state.data[1], 0xffff8000);
	XCTAssertEqual(state.data[2], 0x00002222);
	XCTAssertEqual(state.address[1], 0x3333);

	XCTAssertEqual(24, _machine->get_cycle_count());
}

- (void)testMOVEMw_toIndirect {
	_machine->set_program({
		0x4891, 0x0206		// MOVEM.w A1/D1-D2, (A1)
	});
	auto state = _machine->get_processor_state();
	state.address[1] = 0x4000;
	state.data[1] = 0x11111111;
	state.data[2] = 0x22222222;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();

	XCTAssertEqual(*_machine->ram_at(0x4000), 0x1111);
	XCTAssertEqual(*_machine->ram_at(0x4002), 0x2222);
	XCTAssertEqual(*_machine->ram_at(0x4004), 0x4000);
	XCTAssertEqual(state.address[1], 0x4000);

	XCTAssertEqual(20, _machine->get_cycle_count());
}

// MARK: MOVE

- (void)testMOVEb_DnDn {
	_machine->set_program({
		0x1401		// MOVE.b D1, D2
	});
	auto state = _machine->get_processor_state();
	state.data[1] = 0x12345678;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0x12345678);
	XCTAssertEqual(state.data[2], 0x00000078);
	XCTAssertEqual(state.status & Flag::ConditionCodes, 0);
	XCTAssertEqual(4, _machine->get_cycle_count());
}

- (void)testMOVEl_ImmDn {
	_machine->set_program({
		0x243c, 0x8090, 0xfea1		// MOVE.l #$8090fea1, D2
	});

	_machine->run_for_instructions(1);

	const auto state = _machine->get_processor_state();
	XCTAssertEqual(state.data[2], 0x8090fea1);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Negative);
	XCTAssertEqual(12, _machine->get_cycle_count());
}

- (void)testMOVEs_ImmInd {
	_machine->set_program({
		0x34bc, 0x0000		// MOVE #$0, (A2)
	});
	auto state = _machine->get_processor_state();
	state.address[2] = 0x3000;
	*_machine->ram_at(0x3000) = 0x1234;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.address[2], 0x3000);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Zero);
	XCTAssertEqual(*_machine->ram_at(0x3000), 0);
	XCTAssertEqual(12, _machine->get_cycle_count());
}

- (void)testMOVEl_PostIncPostInc {
	_machine->set_program({
		0x24da		// MOVE.l (A2)+, (A2)+
	});
	auto state = _machine->get_processor_state();
	state.address[2] = 0x3000;
	state.status = Flag::Negative;
	*_machine->ram_at(0x3000) = 0xaaaa;
	*_machine->ram_at(0x3002) = 0xbbbb;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.address[2], 0x3008);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Negative);
	XCTAssertEqual(*_machine->ram_at(0x3000), 0xaaaa);
	XCTAssertEqual(*_machine->ram_at(0x3002), 0xbbbb);
	XCTAssertEqual(*_machine->ram_at(0x3004), 0xaaaa);
	XCTAssertEqual(*_machine->ram_at(0x3006), 0xbbbb);
	XCTAssertEqual(20, _machine->get_cycle_count());
}

- (void)testMOVEl_PostIncPreDec {
	_machine->set_program({
		0x251a		// MOVE.l (A2)+, -(A2)
	});
	auto state = _machine->get_processor_state();
	state.address[2] = 0x3000;
	state.status = Flag::Negative;
	*_machine->ram_at(0x3000) = 0xaaaa;
	*_machine->ram_at(0x3002) = 0xbbbb;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.address[2], 0x3000);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Negative);
	XCTAssertEqual(*_machine->ram_at(0x3000), 0xaaaa);
	XCTAssertEqual(*_machine->ram_at(0x3002), 0xbbbb);
	XCTAssertEqual(*_machine->ram_at(0x3004), 0);
	XCTAssertEqual(*_machine->ram_at(0x3006), 0);
	XCTAssertEqual(20, _machine->get_cycle_count());
}

- (void)testMOVEl_PreDecD16An {
	_machine->set_program({
		0x25a2, 0x1004		// MOVE.L -(A2), 4(A2,D1)
	});
	auto state = _machine->get_processor_state();
	state.address[2] = 0x3004;
	state.data[1] = 0;
	state.status = Flag::Negative;
	*_machine->ram_at(0x3000) = 0xaaaa;
	*_machine->ram_at(0x3002) = 0xbbbb;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.address[2], 0x3000);
	XCTAssertEqual(state.data[1], 0);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Negative);
	XCTAssertEqual(*_machine->ram_at(0x3000), 0xaaaa);
	XCTAssertEqual(*_machine->ram_at(0x3002), 0xbbbb);
	XCTAssertEqual(*_machine->ram_at(0x3004), 0xaaaa);
	XCTAssertEqual(*_machine->ram_at(0x3006), 0xbbbb);
	XCTAssertEqual(28, _machine->get_cycle_count());
}

- (void)testMOVEl_DnXXXl {
	_machine->set_program({
		0x33c1, 0x0000, 0x3000		// MOVE.W D1, ($3000).L
	});
	auto state = _machine->get_processor_state();
	state.data[1] = 0x5678;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0x5678);
	XCTAssertEqual(state.status & Flag::ConditionCodes, 0);
	XCTAssertEqual(*_machine->ram_at(0x3000), 0x5678);
	XCTAssertEqual(*_machine->ram_at(0x3002), 0);
	XCTAssertEqual(16, _machine->get_cycle_count());
}

- (void)testMOVEl_XXXlXXXl {
	_machine->set_program({
		0x23f9, 0x0000, 0x3000, 0x0000, 0x3004		// MOVE.L ($3000).L, ($3004).L
	});
	*_machine->ram_at(0x3002) = 0xeeee;

	_machine->run_for_instructions(1);

	const auto state = _machine->get_processor_state();
	XCTAssertEqual(state.status & Flag::ConditionCodes, 0);	/* !! 8 !! */
	XCTAssertEqual(*_machine->ram_at(0x3002), 0xeeee);
	XCTAssertEqual(*_machine->ram_at(0x3006), 0xeeee);
	XCTAssertEqual(36, _machine->get_cycle_count());
}

// MARK: MOVEA

- (void)testMOVEAl_An {
	_machine->set_program({
		0x244a		// MOVEA.l A2, A2
	});
	auto state = _machine->get_processor_state();
	state.address[2] = 0xffffffff;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.address[2], 0xffffffff);
	XCTAssertEqual(state.status & Flag::ConditionCodes, 0);
	XCTAssertEqual(4, _machine->get_cycle_count());
}

- (void)testMOVEAw_Dn_positive {
	_machine->set_program({
		0x3442		// MOVEA.w D2, A2
	});
	auto state = _machine->get_processor_state();
	state.address[2] = 0xffffffff;
	state.data[2] = 0x12345678;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.address[2], 0x00005678);
	XCTAssertEqual(state.data[2], 0x12345678);
	XCTAssertEqual(state.status & Flag::ConditionCodes, 0);
	XCTAssertEqual(4, _machine->get_cycle_count());
}

- (void)testMOVEAw_Dn_negative {
	_machine->set_program({
		0x3442		// MOVEA.w D2, A2
	});
	auto state = _machine->get_processor_state();
	state.address[2] = 0xffffffff;
	state.data[2] = 0x12348756;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.address[2], 0xffff8756);
	XCTAssertEqual(state.data[2], 0x12348756);
	XCTAssertEqual(state.status & Flag::ConditionCodes, 0);
	XCTAssertEqual(4, _machine->get_cycle_count());
}

- (void)testMOVEAl_Imm {
	_machine->set_program({
		0x247c, 0x0000, 0x0001		// MOVEA.L #$1, A2
	});
	auto state = _machine->get_processor_state();
	state.address[2] = 0xffffffff;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.address[2], 1);
	XCTAssertEqual(state.status & Flag::ConditionCodes, 0);
	XCTAssertEqual(12, _machine->get_cycle_count());
}

// MARK: MOVEP

- (void)testMOVEPw_toDn {
	_machine->set_program({
		0x030e, 0x0004		// MOVEP.w 4(A6), D1
	});
	auto state = _machine->get_processor_state();
	state.address[6] = 0x3000;
	*_machine->ram_at(0x3004) = 0x1200;
	*_machine->ram_at(0x3006) = 0x3400;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.address[6], 0x3000);
	XCTAssertEqual(state.data[1], 0x1234);
	XCTAssertEqual(state.status & Flag::ConditionCodes, 0);
	XCTAssertEqual(16, _machine->get_cycle_count());
}

- (void)testMOVEPl_toDn {
	_machine->set_program({
		0x034e, 0x0002		// MOVEP.l 2(A6), D1
	});
	auto state = _machine->get_processor_state();
	state.address[6] = 0x3000;
	*_machine->ram_at(0x3002) = 0x1200;
	*_machine->ram_at(0x3004) = 0x3400;
	*_machine->ram_at(0x3006) = 0x5600;
	*_machine->ram_at(0x3008) = 0x7800;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.address[6], 0x3000);
	XCTAssertEqual(state.data[1], 0x12345678);
	XCTAssertEqual(state.status & Flag::ConditionCodes, 0);
	XCTAssertEqual(24, _machine->get_cycle_count());
}

- (void)testMOVEPw_fromDn {
	_machine->set_program({
		0x038e, 0x0002		// MOVEP.w D1, 2(A6)
	});
	auto state = _machine->get_processor_state();
	state.address[6] = 0x3000;
	state.data[1] = 0x12345678;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.address[6], 0x3000);
	XCTAssertEqual(*_machine->ram_at(0x3002), 0x5600);
	XCTAssertEqual(*_machine->ram_at(0x3004), 0x7800);

	XCTAssertEqual(state.status & Flag::ConditionCodes, 0);
	XCTAssertEqual(16, _machine->get_cycle_count());
}

- (void)testMOVEPl_fromDn {
	_machine->set_program({
		0x03ce, 0x0002		// MOVEP.l D1, 2(A6)
	});
	auto state = _machine->get_processor_state();
	state.address[6] = 0x3000;
	state.data[1] = 0x12345678;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.address[6], 0x3000);

	XCTAssertEqual(*_machine->ram_at(0x3002), 0x1200);
	XCTAssertEqual(*_machine->ram_at(0x3004), 0x3400);
	XCTAssertEqual(*_machine->ram_at(0x3006), 0x5600);
	XCTAssertEqual(*_machine->ram_at(0x3008), 0x7800);

	XCTAssertEqual(state.status & Flag::ConditionCodes, 0);
	XCTAssertEqual(24, _machine->get_cycle_count());
}

// MARK: MOVEQ

- (void)testMOVEQ_1 {
	_machine->set_program({
		0x7201		// MOVEQ #1, D1
	});
	auto state = _machine->get_processor_state();
	state.data[1] = 0xffffffff;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0x1);
	XCTAssertEqual(state.status & Flag::ConditionCodes, 0);
	XCTAssertEqual(4, _machine->get_cycle_count());
}

- (void)testMOVEQ_ff {
	_machine->set_program({
		0x72ff		// MOVEQ #-1, D1
	});
	auto state = _machine->get_processor_state();
	state.status |= Flag::Extend | Flag::Carry | Flag::Overflow;

	_machine->set_processor_state(state);

	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0xffffffff);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend | Flag::Negative);
	XCTAssertEqual(4, _machine->get_cycle_count());
}

- (void)testMOVEQ_80 {
	_machine->set_program({
		0x7280		// MOVEQ #$80, D1
	});
	auto state = _machine->get_processor_state();
	state.status |= Flag::Extend | Flag::Carry | Flag::Overflow;
	state.data[1] = 0x12345678;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0xffffff80);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend | Flag::Negative);
	XCTAssertEqual(4, _machine->get_cycle_count());
}

- (void)testMOVEQ_00 {
	_machine->set_program({
		0x7200		// MOVEQ #00, D1
	});
	auto state = _machine->get_processor_state();
	state.status |= Flag::Extend | Flag::Carry | Flag::Overflow;
	state.data[1] = 0x12345678;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend | Flag::Zero);
	XCTAssertEqual(4, _machine->get_cycle_count());
}

// MARK: MOVE from SR

- (void)testMoveFromSR {
	_machine->set_program({
		0x40c1		// MOVE SR, D1
	});
	auto state = _machine->get_processor_state();
	state.status = 0x271f;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0x271f);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::ConditionCodes);
	XCTAssertEqual(6, _machine->get_cycle_count());
}

// MARK: MOVE to CCR

- (void)testMoveToCCR {
	_machine->set_program({
		0x44fc, 0x001f		// MOVE #$1f, CCR
	});
	auto state = _machine->get_processor_state();
	state.status = 0;	// i.e. not even supervisor.

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.status & Flag::ConditionCodes, 0x1f);
	XCTAssertEqual(16, _machine->get_cycle_count());
}

// MARK: MOVE to SR

- (void)testMoveToSR {
	_machine->set_program({
		0x46fc, 0x0700		// MOVE #$700, SR
	});
	auto state = _machine->get_processor_state();
	state.supervisor_stack_pointer = 0x3000;
	state.user_stack_pointer = 0;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.stack_pointer(), 0);
	XCTAssertEqual(state.status & Flag::ConditionCodes, 0);
	XCTAssertEqual(16, _machine->get_cycle_count());
}

// MARK: MOVE USP

- (void)testMoveUSP {
	_machine->set_program({
		0x4e69		// MOVE USP, A1
	});
	auto state = _machine->get_processor_state();
	state.address[1] = 0x12348756;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.address[1], 0);
}

// MARK: PEA

- (void)testPEA_A1 {
	_machine->set_program({
		0x4851		// PEA (A1)
	});
	auto state = _machine->get_processor_state();
	state.address[1] = 0x3000ffff;
	_machine->set_initial_stack_pointer(0x1996);

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.address[1], 0x3000ffff);
	XCTAssertEqual(state.stack_pointer(), 0x1992);
	XCTAssertEqual(*_machine->ram_at(0x1992), 0x3000);
	XCTAssertEqual(*_machine->ram_at(0x1994), 0xffff);
	XCTAssertEqual(12, _machine->get_cycle_count());
}

- (void)testPEA_A7 {
	_machine->set_program({
		0x4857		// PEA (A7)
	});
	_machine->set_initial_stack_pointer(0x1012);

	_machine->run_for_instructions(1);

	const auto state = _machine->get_processor_state();
	XCTAssertEqual(state.stack_pointer(), 0x100e);
	XCTAssertEqual(*_machine->ram_at(0x1010), 0x1012);
	XCTAssertEqual(*_machine->ram_at(0x1008), 0x0000);
	XCTAssertEqual(12, _machine->get_cycle_count());
}

- (void)testPEA_4A7 {
	_machine->set_program({
		0x486f, 0x0004		// PEA 4(A7)
	});
	_machine->set_initial_stack_pointer(0x1012);

	_machine->run_for_instructions(1);

	const auto state = _machine->get_processor_state();
	XCTAssertEqual(state.stack_pointer(), 0x100e);
	XCTAssertEqual(*_machine->ram_at(0x1010), 0x1016);
	XCTAssertEqual(*_machine->ram_at(0x1008), 0x0000);
	XCTAssertEqual(16, _machine->get_cycle_count());
}

- (void)testPEA_XXXw {
	_machine->set_program({
		0x4878, 0x3000		// PEA ($3000).w
	});
	_machine->set_initial_stack_pointer(0x1996);

	_machine->run_for_instructions(1);

	const auto state = _machine->get_processor_state();
	XCTAssertEqual(state.stack_pointer(), 0x1992);
	XCTAssertEqual(*_machine->ram_at(0x1992), 0x0000);
	XCTAssertEqual(*_machine->ram_at(0x1994), 0x3000);
	XCTAssertEqual(16, _machine->get_cycle_count());
}

- (void)testPEA_XXXl {
	_machine->set_program({
		0x4879, 0x1234, 0x5678		// PEA ($12345678)
	});
	_machine->set_initial_stack_pointer(0x1996);

	_machine->run_for_instructions(1);

	const auto state = _machine->get_processor_state();
	XCTAssertEqual(state.stack_pointer(), 0x1992);
	XCTAssertEqual(*_machine->ram_at(0x1992), 0x1234);
	XCTAssertEqual(*_machine->ram_at(0x1994), 0x5678);
	XCTAssertEqual(20, _machine->get_cycle_count());
}

// MARK: ROL

- (void)testROLb_8 {
	_machine->set_program({
		0xe118		// ROL.B #8, D0
	});
	auto state = _machine->get_processor_state();
	state.data[0] = 0xce3dd567;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[0], 0xce3dd567);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Carry);
	XCTAssertEqual(22, _machine->get_cycle_count());
}

- (void)testROLb_1 {
	_machine->set_program({
		0xe318		// ROL.B #1, D0
	});
	auto state = _machine->get_processor_state();
	state.data[0] = 0xce3dd567;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[0], 0xce3dd5ce);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Negative);
	XCTAssertEqual(8, _machine->get_cycle_count());
}

- (void)testROLb_2 {
	_machine->set_program({
		0xe518		// ROL.B #2, D0
	});
	auto state = _machine->get_processor_state();
	state.data[0] = 0xce3dd567;
	state.status = Flag::ConditionCodes;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[0], 0xce3dd59d);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Negative | Flag::Extend | Flag::Carry);
	XCTAssertEqual(10, _machine->get_cycle_count());
}

- (void)testROLb_7 {
	_machine->set_program({
		0xef18		// ROL.B #7, D0
	});
	auto state = _machine->get_processor_state();
	state.data[0] = 0xce3dd567;
	state.status = Flag::ConditionCodes;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[0], 0xce3dd5b3);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Negative | Flag::Extend | Flag::Carry);
	XCTAssertEqual(20, _machine->get_cycle_count());
}

- (void)testROLw_8 {
	_machine->set_program({
		0xe158		// ROL.w #7, D0
	});
	auto state = _machine->get_processor_state();
	state.data[0] = 0xce3dd567;
	state.status = Flag::ConditionCodes;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[0], 0xce3d67d5);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend | Flag::Carry);
	XCTAssertEqual(22, _machine->get_cycle_count());
}

- (void)testROLl_3 {
	_machine->set_program({
		0xe798		// ROL.l #3, D0
	});
	auto state = _machine->get_processor_state();
	state.data[0] = 0xce3dd567;
	state.status = Flag::ConditionCodes;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[0], 0x71eeab3e);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend);
	XCTAssertEqual(14, _machine->get_cycle_count());
}

- (void)performROLw_D1D0d1:(uint32_t)d1 {
	_machine->set_program({
		0xe378		// ROL.l D1, D0
	});
	auto state = _machine->get_processor_state();
	state.data[0] = 0xce3dd567;
	state.data[1] = d1;
	state.status = Flag::ConditionCodes;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);
}

- (void)testROLw_D1D0_20 {
	[self performROLw_D1D0d1:20];
	const auto state = _machine->get_processor_state();
	XCTAssertEqual(state.data[0], 0xce3d567d);
	XCTAssertEqual(state.data[1], 20);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend | Flag::Carry);
	XCTAssertEqual(46, _machine->get_cycle_count());
}

- (void)testROLw_D1D0_36 {
	[self performROLw_D1D0d1:36];
	const auto state = _machine->get_processor_state();
	XCTAssertEqual(state.data[0], 0xce3d567d);
	XCTAssertEqual(state.data[1], 36);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend | Flag::Carry);
	XCTAssertEqual(78, _machine->get_cycle_count());
}

- (void)testROLw_D1D0_0 {
	[self performROLw_D1D0d1:0];
	const auto state = _machine->get_processor_state();
	XCTAssertEqual(state.data[0], 0xce3dd567);
	XCTAssertEqual(state.data[1], 0);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend | Flag::Negative);
	XCTAssertEqual(6, _machine->get_cycle_count());
}

- (void)testROLl_D1D0_200 {
	_machine->set_program({
		0xe3b8		// ROL.l D1, D0
	});
	auto state = _machine->get_processor_state();
	state.data[0] = 0xce3dd567;
	state.data[1] = 200;
	state.status = Flag::ConditionCodes;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[0], 0x3dd567ce);
	XCTAssertEqual(state.data[1], 200);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend);
	XCTAssertEqual(24, _machine->get_cycle_count());
}

- (void)performROLw_3000:(uint16_t)storedValue {
	_machine->set_program({
		0xe7f8, 0x3000		// ROL.w ($3000).w
	});
	*_machine->ram_at(0x3000) = storedValue;

	_machine->run_for_instructions(1);

	XCTAssertEqual(16, _machine->get_cycle_count());
}

- (void)testROLm_d567 {
	[self performROLw_3000:0xd567];

	const auto state = _machine->get_processor_state();
	XCTAssertEqual(*_machine->ram_at(0x3000), 0xaacf);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Negative | Flag::Carry);
}

- (void)testROLm_0 {
	[self performROLw_3000:0];

	const auto state = _machine->get_processor_state();
	XCTAssertEqual(*_machine->ram_at(0x3000), 0);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Zero);
}

// MARK: ROR

- (void)performRORbIMM:(uint16_t)immediate {
	if(immediate == 8) immediate = 0;
	_machine->set_program({
		uint16_t(0xe018 | (immediate << 9))		// ROR.b #, D0
	});
	auto state = _machine->get_processor_state();
	state.data[0] = 0xce3dd599;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);
}

- (void)testRORb_IMM_8 {
	[self performRORbIMM:8];

	const auto state = _machine->get_processor_state();
	XCTAssertEqual(state.data[0], 0xce3dd599);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Carry | Flag::Negative);
	XCTAssertEqual(22, _machine->get_cycle_count());
}

- (void)testRORb_IMM_1 {
	[self performRORbIMM:1];

	const auto state = _machine->get_processor_state();
	XCTAssertEqual(state.data[0], 0xce3dd5cc);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Carry | Flag::Negative);
	XCTAssertEqual(8, _machine->get_cycle_count());
}

- (void)testRORb_IMM_4 {
	[self performRORbIMM:4];

	const auto state = _machine->get_processor_state();
	XCTAssertEqual(state.data[0], 0xce3dd599);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Carry | Flag::Negative);
	XCTAssertEqual(14, _machine->get_cycle_count());
}

- (void)testRORb_IMM_7 {
	[self performRORbIMM:7];

	const auto state = _machine->get_processor_state();
	XCTAssertEqual(state.data[0], 0xce3dd533);
	XCTAssertEqual(state.status & Flag::ConditionCodes, 0);
	XCTAssertEqual(20, _machine->get_cycle_count());
}

- (void)testRORw_IMM {
	_machine->set_program({
		0xec58		// ROR.w #6, D0
	});
	auto state = _machine->get_processor_state();
	state.data[0] = 0xce3dd599;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[0], 0xce3d6756);
	XCTAssertEqual(state.status & Flag::ConditionCodes, 0);
	XCTAssertEqual(18, _machine->get_cycle_count());
}

- (void)testRORl_IMM {
	_machine->set_program({
		0xea98		// ROR.l #5, D0
	});
	auto state = _machine->get_processor_state();
	state.data[0] = 0xce3dd599;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[0], 0xce71eeac);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Carry | Flag::Negative);
	XCTAssertEqual(18, _machine->get_cycle_count());
}

- (void)testRORb_Dn {
	_machine->set_program({
		0xe238		// ROR.b D1, D0
	});
	auto state = _machine->get_processor_state();
	state.data[0] = 0xce3dd599;
	state.data[1] = 20;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[0], 0xce3dd599);
	XCTAssertEqual(state.data[1], 20);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Carry | Flag::Negative);
	XCTAssertEqual(46, _machine->get_cycle_count());
}

- (void)testRORl_Dn {
	_machine->set_program({
		0xe2b8		// ROR.l D1, D0
	});
	auto state = _machine->get_processor_state();
	state.data[0] = 0xce3dd599;
	state.data[1] = 26;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[0], 0x8f756673);
	XCTAssertEqual(state.data[1], 26);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Carry | Flag::Negative);
	XCTAssertEqual(60, _machine->get_cycle_count());
}

- (void)performRORw_3000:(uint16_t)storedValue {
	_machine->set_program({
		0xe6f8, 0x3000		// ROR.w ($3000).w
	});
	*_machine->ram_at(0x3000) = storedValue;

	_machine->run_for_instructions(1);

	XCTAssertEqual(16, _machine->get_cycle_count());
}

- (void)testRORm_d567 {
	[self performRORw_3000:0xd567];

	const auto state = _machine->get_processor_state();
	XCTAssertEqual(*_machine->ram_at(0x3000), 0xeab3);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Negative | Flag::Carry);
}

- (void)testRORm_d560 {
	[self performRORw_3000:0xd560];

	const auto state = _machine->get_processor_state();
	XCTAssertEqual(*_machine->ram_at(0x3000), 0x6ab0);
	XCTAssertEqual(state.status & Flag::ConditionCodes, 0);
}

// MARK: Scc

- (void)testSFDn {
	_machine->set_program({
		0x51c0		// SF D0
	});
	auto state = _machine->get_processor_state();
	state.data[0] = 0x12345678;
	state.status = Flag::Extend;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[0], 0x12345600);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend);
}

- (void)testSTDn {
	_machine->set_program({
		0x50c0		// ST D0
	});
	auto state = _machine->get_processor_state();
	state.data[0] = 0x12345678;
	state.status = Flag::Extend;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[0], 0x123456ff);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend);
}

- (void)testSLSDn {
	_machine->set_program({
		0x53c0		// SLS D0
	});
	auto state = _machine->get_processor_state();
	state.data[0] = 0x12345678;
	state.status = Flag::ConditionCodes;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[0], 0x123456ff);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::ConditionCodes);
}

- (void)testSGTAnXTrue {
	_machine->set_program({
		0x5ee8, 0x0002		// SGT 2(a0)
	});
	auto state = _machine->get_processor_state();
	state.address[0] = 0x3000;
	*_machine->ram_at(0x3002) = 0x8800;
	state.status = Flag::Extend;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(*_machine->ram_at(0x3002), 0xff00);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Extend);
}

- (void)testSGTAnXFalse {
	_machine->set_program({
		0x5ee8, 0x0002		// SGT 2(a0)
	});
	auto state = _machine->get_processor_state();
	state.address[0] = 0x3000;
	*_machine->ram_at(0x3002) = 0x8800;
	state.status = Flag::ConditionCodes;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(*_machine->ram_at(0x3002), 0x0000);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::ConditionCodes);
}


// MARK: SWAP

- (void)testSwap {
	_machine->set_program({
		0x4841		// SWAP D1
	});
	auto state = _machine->get_processor_state();
	state.data[1] = 0x12348756;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.data[1], 0x87561234);
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Negative);
}

// MARK: TST

- (void)testTSTw_Dn {
	_machine->set_program({
		0x4a44		// TST.w D4
	});
	auto state = _machine->get_processor_state();
	state.status |= Flag::Extend | Flag::Carry | Flag::Overflow;
	state.data[4] = 0xfff1;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Negative | Flag::Extend);
	XCTAssertEqual(state.data[4], 0xfff1);
	XCTAssertEqual(4, _machine->get_cycle_count());
}

- (void)testTSTl_Dn {
	_machine->set_program({
		0x4a84		// TST.l D4
	});
	auto state = _machine->get_processor_state();
	state.status |= Flag::Extend | Flag::Carry | Flag::Overflow;
	state.data[4] = 0;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.status & Flag::ConditionCodes, Flag::Zero | Flag::Extend);
	XCTAssertEqual(state.data[4], 0);
	XCTAssertEqual(4, _machine->get_cycle_count());
}

// Omitted: test that tst.w A0 doesn't decode.

// MARK: UNLINK

- (void)testUNLINK_A6 {
	_machine->set_program({
		0x4e5e		// UNLNK A6
	});

	auto state = _machine->get_processor_state();
	state.address[6] = 0x3000;
	*_machine->ram_at(0x3000) = 0x0000;
	*_machine->ram_at(0x3002) = 0x4000;

	_machine->set_processor_state(state);
	_machine->run_for_instructions(1);

	state = _machine->get_processor_state();
	XCTAssertEqual(state.address[6], 0x4000);
	XCTAssertEqual(state.supervisor_stack_pointer, 0x3004);
	XCTAssertEqual(12, _machine->get_cycle_count());
}

- (void)testUNLINK_A7 {
	_machine->set_program({
		0x4e5f		// UNLNK A7
	});
	_machine->set_initial_stack_pointer(0x3000);
	*_machine->ram_at(0x3000) = 0x0000;
	*_machine->ram_at(0x3002) = 0x4000;

	_machine->run_for_instructions(1);

	const auto state = _machine->get_processor_state();
	XCTAssertEqual(state.supervisor_stack_pointer, 0x4000);
	XCTAssertEqual(12, _machine->get_cycle_count());
}

@end
