//
//  TIA.hpp
//  Clock Signal
//
//  Created by Thomas Harte on 28/01/2017.
//  Copyright © 2017 Thomas Harte. All rights reserved.
//

#ifndef TIA_hpp
#define TIA_hpp

#include <cstdint>
#include "../CRTMachine.hpp"

namespace Atari2600 {

class TIA {
	public:
		TIA();
		// The supplied hook is for unit testing only; if instantiated with a line_end_function then it will
		// be called with the latest collision buffer upon the conclusion of each line. What's a collision
		// buffer? It's an implementation detail. If you're not writing a unit test, leave it alone.
		TIA(std::function<void(uint8_t *output_buffer)> line_end_function);

		enum class OutputMode {
			NTSC, PAL
		};

		/*!
			Advances the TIA by @c number_of_cycles cycles. Any queued setters take effect in the
			first cycle performed.
		*/
		void run_for_cycles(int number_of_cycles);
		void set_output_mode(OutputMode output_mode);

		void set_sync(bool sync);
		void set_blank(bool blank);
		void reset_horizontal_counter(); 						// Reset is delayed by four cycles.

		/*!
			@returns the number of cycles between (current TIA time) + from_offset to the current or
			next horizontal blanking period. Returns numbers in the range [0, 227].
		*/
		int get_cycles_until_horizontal_blank(unsigned int from_offset);

		void set_background_colour(uint8_t colour);

		void set_playfield(uint16_t offset, uint8_t value);
		void set_playfield_control_and_ball_size(uint8_t value);
		void set_playfield_ball_colour(uint8_t colour);

		void set_player_number_and_size(int player, uint8_t value);
		void set_player_graphic(int player, uint8_t value);
		void set_player_reflected(int player, bool reflected);
		void set_player_delay(int player, bool delay);
		void set_player_position(int player);
		void set_player_motion(int player, uint8_t motion);
		void set_player_missile_colour(int player, uint8_t colour);

		void set_missile_enable(int missile, bool enabled);
		void set_missile_position(int missile);
		void set_missile_position_to_player(int missile, bool lock);
		void set_missile_motion(int missile, uint8_t motion);

		void set_ball_enable(bool enabled);
		void set_ball_delay(bool delay);
		void set_ball_position();
		void set_ball_motion(uint8_t motion);

		void move();
		void clear_motion();

		uint8_t get_collision_flags(int offset);
		void clear_collision_flags();

		virtual std::shared_ptr<Outputs::CRT::CRT> get_crt() { return crt_; }

	private:
		TIA(bool create_crt);
		std::shared_ptr<Outputs::CRT::CRT> crt_;
		std::function<void(uint8_t *output_buffer)> line_end_function_;

		// the master counter; counts from 0 to 228 with all visible pixels being in the final 160
		int horizontal_counter_;

		// contains flags to indicate whether sync or blank are currently active
		int output_mode_;

		// keeps track of the target pixel buffer for this line and when it was acquired, and a corresponding collision buffer
		alignas(alignof(uint32_t)) uint8_t collision_buffer_[160];
		enum class CollisionType : uint8_t {
			Playfield	= (1 << 0),
			Ball		= (1 << 1),
			Player0		= (1 << 2),
			Player1		= (1 << 3),
			Missile0	= (1 << 4),
			Missile1	= (1 << 5)
		};

		int collision_flags_;
		int collision_flags_by_buffer_vaules_[64];

		// colour mapping tables
		enum class ColourMode {
			Standard = 0,
			ScoreLeft,
			ScoreRight,
			OnTop
		};
		uint8_t colour_mask_by_mode_collision_flags_[4][64];	// maps from [ColourMode][CollisionMark] to colour_pallete_ entry

		enum class ColourIndex {
			Background = 0,
			PlayfieldBall,
			PlayerMissile0,
			PlayerMissile1
		};
		uint8_t colour_palette_[4];

		// playfield state
		int background_half_mask_;
		enum class PlayfieldPriority {
			Standard,
			Score,
			OnTop
		} playfield_priority_;
		uint32_t background_[2];	// contains two 20-bit bitfields representing the background state;
									// at index 0 is the left-hand side of the playfield with bit 0 being
									// the first bit to display, bit 1 the second, etc. Index 1 contains
									// a mirror image of index 0. If the playfield is being displayed in
									// mirroring mode, background_[0] will be output on the left and
									// background_[1] on the right; otherwise background_[0] will be
									// output twice.

		// objects
		template<class T> struct Object {
			// the two programmer-set values
			int position;
			int motion;

			// motion_step_ is the current motion counter value; motion_time_ is the next time it will fire
			int motion_step;
			int motion_time;

			// indicates whether this object is currently undergoing motion
			bool is_moving;

			Object() : position(0), motion(0), motion_step(0), motion_time(0), is_moving(false) {};
		};

		// player state
		struct Player: public Object<Player> {
			Player() :
				adder(4),
				copy_flags(0),
				graphic{0, 0},
				reverse_mask(false),
				graphic_index(0),
				pixel_position(32),
				pixel_counter(0),
				latched_pixel4_time(-1),
				copy_index_(0),
				queue_read_pointer_(0),
				queue_write_pointer_(0) {}

			int adder;
			int copy_flags;		// a bit field, corresponding to the first few values of NUSIZ
			uint8_t graphic[2];	// the player graphic; 1 = new, 0 = current
			int reverse_mask;	// 7 for a reflected player, 0 for normal
			int graphic_index;

			int pixel_position, pixel_counter;
			int latched_pixel4_time;
			const bool enqueues = true;

			inline void skip_pixels(const int count, int from_horizontal_counter) {
				int old_pixel_counter = pixel_counter;
				pixel_position = std::min(32, pixel_position + count * adder);
				pixel_counter += count;
				if(!copy_index_ && old_pixel_counter < 4 && pixel_counter >= 4) {
					latched_pixel4_time = from_horizontal_counter + 4 - old_pixel_counter;
				}
			}

			inline void reset_pixels(int copy) {
				pixel_position = pixel_counter = 0;
				copy_index_ = copy;
			}

			inline void output_pixels(uint8_t *const target, const int count, const uint8_t collision_identity, int from_horizontal_counter) {
				output_pixels(target, count, collision_identity, pixel_position, adder, reverse_mask);
				skip_pixels(count, from_horizontal_counter);
			}

			void dequeue_pixels(uint8_t *const target, const uint8_t collision_identity, const int time_now) {
				while(queue_read_pointer_ != queue_write_pointer_) {
					uint8_t *const start_ptr = &target[queue_[queue_read_pointer_].start];
					if(queue_[queue_read_pointer_].end > time_now) {
						const int length = time_now - queue_[queue_read_pointer_].start;
						output_pixels(start_ptr, length, collision_identity, queue_[queue_read_pointer_].pixel_position, queue_[queue_read_pointer_].adder, queue_[queue_read_pointer_].reverse_mask);
						queue_[queue_read_pointer_].pixel_position += length * queue_[queue_read_pointer_].adder;
						queue_[queue_read_pointer_].start = time_now;
						return;
					} else {
						output_pixels(start_ptr, queue_[queue_read_pointer_].end - queue_[queue_read_pointer_].start, collision_identity, queue_[queue_read_pointer_].pixel_position, queue_[queue_read_pointer_].adder, queue_[queue_read_pointer_].reverse_mask);
					}
					queue_read_pointer_ = (queue_read_pointer_ + 1)&3;
				}
			}

			void enqueue_pixels(const int start, const int end, int from_horizontal_counter) {
				queue_[queue_write_pointer_].start = start;
				queue_[queue_write_pointer_].end = end;
				queue_[queue_write_pointer_].pixel_position = pixel_position;
				queue_[queue_write_pointer_].adder = adder;
				queue_[queue_write_pointer_].reverse_mask = reverse_mask;
				queue_write_pointer_ = (queue_write_pointer_ + 1)&3;
				skip_pixels(end - start, from_horizontal_counter);
			}

			private:
				int copy_index_;
				struct QueuedPixels {
					int start, end;
					int pixel_position;
					int adder;
					int reverse_mask;
					QueuedPixels() : start(0), end(0), pixel_position(0), adder(0), reverse_mask(false) {}
				} queue_[4];
				int queue_read_pointer_, queue_write_pointer_;

				inline void output_pixels(uint8_t *const target, const int count, const uint8_t collision_identity, int pixel_position, int adder, int reverse_mask) {
					if(pixel_position == 32 || !graphic[graphic_index]) return;
					int output_cursor = 0;
					while(pixel_position < 32 && output_cursor < count) {
						int shift = (pixel_position >> 2) ^ reverse_mask;
						target[output_cursor] |= ((graphic[graphic_index] >> shift)&1) * collision_identity;
						output_cursor++;
						pixel_position += adder;
					}
				}

		} player_[2];

		// common actor for things that appear as a horizontal run of pixels
		struct HorizontalRun: public Object<HorizontalRun> {
			int pixel_position;
			int size;
			const bool enqueues = false;

			inline void skip_pixels(const int count, int from_horizontal_counter) {
				pixel_position = std::max(0, pixel_position - count);
			}

			inline void reset_pixels(int copy) {
				pixel_position = size;
			}

			inline void output_pixels(uint8_t *const target, const int count, const uint8_t collision_identity, int from_horizontal_counter) {
				int output_cursor = 0;
				while(pixel_position && output_cursor < count)
				{
					target[output_cursor] |= collision_identity;
					output_cursor++;
					pixel_position--;
				}
			}

			void dequeue_pixels(uint8_t *const target, const uint8_t collision_identity, const int time_now) {}
			void enqueue_pixels(const int start, const int end, int from_horizontal_counter) {}

			HorizontalRun() : pixel_position(0), size(1) {}
		};


		// missile state
		struct Missile: public HorizontalRun {
			bool enabled;
			bool locked_to_player;
			int copy_flags;

			inline void output_pixels(uint8_t *const target, const int count, const uint8_t collision_identity, int from_horizontal_counter) {
				if(!pixel_position) return;
				if(enabled && !locked_to_player) {
					HorizontalRun::output_pixels(target, count, collision_identity, from_horizontal_counter);
				} else {
					skip_pixels(count, from_horizontal_counter);
				}
			}

			Missile() : enabled(false), copy_flags(0) {}
		} missile_[2];

		// ball state
		struct Ball: public HorizontalRun {
			bool enabled[2];
			int enabled_index;
			const int copy_flags = 0;

			inline void output_pixels(uint8_t *const target, const int count, const uint8_t collision_identity, int from_horizontal_counter) {
				if(!pixel_position) return;
				if(enabled[enabled_index]) {
					HorizontalRun::output_pixels(target, count, collision_identity, from_horizontal_counter);
				} else {
					skip_pixels(count, from_horizontal_counter);
				}
			}

			Ball() : enabled{false, false}, enabled_index(0) {}
		} ball_;

		// motion
		bool horizontal_blank_extend_;
		template<class T> void perform_border_motion(T &object, int start, int end);
		template<class T> void perform_motion_step(T &object);

		// drawing methods and state
		void draw_missile(Missile &, Player &, const uint8_t collision_identity, int start, int end);
		template<class T> void draw_object(T &, const uint8_t collision_identity, int start, int end);
		template<class T> void draw_object_visible(T &, const uint8_t collision_identity, int start, int end, int time_now);
		inline void draw_playfield(int start, int end);

		inline void output_for_cycles(int number_of_cycles);
		inline void output_line();

		int pixels_start_location_;
		uint8_t *pixel_target_;
		inline void output_pixels(int start, int end);
};

}

#endif /* TIA_hpp */
