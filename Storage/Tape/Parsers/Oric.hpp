//
//  Oric.hpp
//  Clock Signal
//
//  Created by Thomas Harte on 06/11/2016.
//  Copyright © 2016 Thomas Harte. All rights reserved.
//

#ifndef Storage_Tape_Parsers_Oric_hpp
#define Storage_Tape_Parsers_Oric_hpp

#include "TapeParser.hpp"

namespace Storage {
namespace Tape {
namespace Oric {

enum class WaveType {
	Short,	// i.e. 416µs
	Medium,	// i.e. 624µs
	Long,	// i.e. 832µs
	Unrecognised
};

enum class SymbolType {
	One, Zero, FoundFast, FoundSlow
};

class Parser: public Storage::Tape::Parser<WaveType, SymbolType> {
	public:
		int get_next_byte(const std::shared_ptr<Storage::Tape::Tape> &tape, bool use_fast_encoding);
		bool sync_and_get_encoding_speed(const std::shared_ptr<Storage::Tape::Tape> &tape);

	private:
		void process_pulse(Storage::Tape::Tape::Pulse pulse);
		void inspect_waves(const std::vector<WaveType> &waves);

		enum DetectionMode {
			FastData,
			SlowData,
			FastZero,
			SlowZero,
			Sync
		} detection_mode_;
		bool wave_was_high_;
		float cycle_length_;

		struct Pattern
		{
			WaveType type;
			int count;
		};
		size_t pattern_matching_depth(const std::vector<WaveType> &waves, Pattern *pattern);
};


}
}
}

#endif /* Oric_hpp */
