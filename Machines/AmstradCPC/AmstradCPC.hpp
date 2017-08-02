//
//  AmstradCPC.hpp
//  Clock Signal
//
//  Created by Thomas Harte on 30/07/2017.
//  Copyright © 2017 Thomas Harte. All rights reserved.
//

#ifndef AmstradCPC_hpp
#define AmstradCPC_hpp

#include "../ConfigurationTarget.hpp"
#include "../CRTMachine.hpp"

namespace AmstradCPC {

enum ROMType: uint8_t {
	OS464, OS664, OS6128,
	BASIC464, BASIC664, BASIC6128,
	AMSDOS
};

enum Key: uint16_t {
#define Line(l, k1, k2, k3, k4, k5, k6, k7, k8)	\
	k1 = (l << 4) | 0x07,\
	k2 = (l << 4) | 0x06,\
	k3 = (l << 4) | 0x05,\
	k4 = (l << 4) | 0x04,\
	k5 = (l << 4) | 0x03,\
	k6 = (l << 4) | 0x02,\
	k7 = (l << 4) | 0x01,\
	k8 = (l << 4) | 0x00,

	Line(0, KeyFDot, KeyEnter, KeyF3, KeyF6, KeyF9, KeyDown, KeyRight, KeyUp)
	Line(1, KeyF0, KeyF2, KeyF1, KeyF5, KeyF8, KeyF7, KeyCopy, KeyLeft)
	Line(2, KeyControl, KeyBackSlash, KeyShift, KeyF4, KeyRightSquareBracket, KeyReturn, KeyLeftSquareBracket, KeyClear)
	Line(3, KeyFullStop, KeyForwardSlash, KeyColon, KeySemicolon, KeyP, KeyAt, KeyMinus, KeyCaret)
	Line(4, KeyComma, KeyM, KeyK, KeyL, KeyI, KeyO, Key9, Key0)
	Line(5, KeySpace, KeyN, KeyJ, KeyH, KeyY, KeyU, Key7, Key8)
	Line(6, KeyV, KeyB, KeyF, KeyG, KeyT, KeyR, Key5, Key6)
	Line(7, KeyX, KeyC, KeyD, KeyS, KeyW, KeyE, Key3, Key4)
	Line(8, KeyZ, KeyCapsLock, KeyA, KeyTab, KeyQ, KeyEscape, Key2, Key1)
	Line(9, KeyDelete, KeyJoy1Fire3, KeyJoy2Fire2, KeyJoy1Fire1, KeyJoy1Right, KeyJoy1Left, KeyJoy1Down, KeyJoy1Up)

#undef Line
};

class Machine:
	public CRTMachine::Machine,
	public ConfigurationTarget::Machine {
	public:
		static Machine *AmstradCPC();

		virtual void set_rom(ROMType type, std::vector<uint8_t> data) = 0;
		virtual void set_key_state(uint16_t key, bool isPressed) = 0;
		virtual void clear_all_keys() = 0;
};

}

#endif /* AmstradCPC_hpp */
