//
//  CommodoreTAP.hpp
//  Clock Signal
//
//  Created by Thomas Harte on 25/06/2016.
//  Copyright © 2016 Thomas Harte. All rights reserved.
//

#ifndef CommodoreTAP_hpp
#define CommodoreTAP_hpp

#include "../Tape.hpp"
#include <stdint.h>

namespace Storage {

/*!
	Provides a @c Tape containing a Commodore-format tape image, which is simply a timed list of zero crossings.
*/
class CommodoreTAP: public Tape {
	public:
		/*!
			Constructs a @c CommodoreTAP containing content from the file with name @c file_name.

			@throws ErrorNotCommodoreTAP if this file could not be opened and recognised as a valid Commodore-format TAP.
		*/
		CommodoreTAP(const char *file_name);
		~CommodoreTAP();

		enum {
			ErrorNotCommodoreTAP
		};

		// implemented to satisfy @c Tape
		Pulse get_next_pulse();
		void reset();

	private:
		FILE *_file;
		bool _updated_layout;
		uint32_t _file_size;

		Pulse _current_pulse;
};

}

#endif /* CommodoreTAP_hpp */