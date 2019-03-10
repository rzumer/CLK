//
//  EmuTOSTests.m
//  Clock SignalTests
//
//  Created by Thomas Harte on 10/03/2019.
//  Copyright © 2019 Thomas Harte. All rights reserved.
//

#import <XCTest/XCTest.h>

#include <cassert>
#include "68000.hpp"
#include "CSROMFetcher.hpp"

class EmuTOS: public CPU::MC68000::BusHandler {
	public:
		EmuTOS(const std::vector<uint8_t> &emuTOS) : m68000_(*this) {
			assert(!(emuTOS.size() & 1));
			emuTOS_.resize(emuTOS.size() / 2);

			for(size_t c = 0; c < emuTOS_.size(); ++c) {
				emuTOS_[c] = (emuTOS[c << 1] << 8) | emuTOS[(c << 1) + 1];
			}
		}

		void run_for(HalfCycles cycles) {
			m68000_.run_for(cycles);
		}

		HalfCycles perform_bus_operation(const CPU::MC68000::Microcycle &cycle, int is_supervisor) {
			switch(cycle.operation & (CPU::MC68000::Microcycle::LowerData | CPU::MC68000::Microcycle::UpperData)) {
				case 0: break;
				case CPU::MC68000::Microcycle::LowerData:
					cycle.value->halves.low = emuTOS_[*cycle.address >> 1] >> 8;
				break;
				case CPU::MC68000::Microcycle::UpperData:
					cycle.value->halves.high = emuTOS_[*cycle.address >> 1] & 0xff;
				break;
				case CPU::MC68000::Microcycle::UpperData | CPU::MC68000::Microcycle::LowerData:
					cycle.value->full = emuTOS_[*cycle.address >> 1];
				break;
			}

			return HalfCycles(0);
		}

	private:
		CPU::MC68000::Processor<EmuTOS, true> m68000_;

		std::vector<uint16_t> emuTOS_;
};

@interface EmuTOSTests : XCTestCase
@end

@implementation EmuTOSTests {
	std::unique_ptr<EmuTOS> _machine;
}

- (void)setUp {
    // Put setup code here. This method is called before the invocation of each test method in the class.
    const auto roms = CSROMFetcher()("AtariST", {"etos192uk.img"});
    _machine.reset(new EmuTOS(*roms[0]));
}

- (void)tearDown {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
}

- (void)testExample {
    // This is an example of a functional test case.
    // Use XCTAssert and related functions to verify your tests produce the correct results.
    _machine->run_for(HalfCycles(400));
}

@end