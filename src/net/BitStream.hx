package net;

import haxe.io.FPHelper;
import haxe.io.BytesInput;
import haxe.io.Bytes;

class InputBitStream {
	var data:Bytes;
	var position:Int;
	var shift:Int;

	public function new(data:Bytes) {
		this.data = data;
		this.position = 0;
		this.shift = 0;
	}

	function readBits(bits:Int = 8) {
		if (this.shift + bits >= 8) {
			var extra = (this.shift + bits) % 8;
			var remain = bits - extra;
			var first = data.get(position) >> shift;
			var result = first;
			this.position++;
			if (extra > 0) {
				var second = (data.get(position) & (0xFF >> (8 - extra))) << remain;
				result |= second;
			}
			this.shift = extra;
			return result;
		} else {
			var result = (data.get(position) >> shift) & (0xFF >> (8 - bits));
			shift += bits;

			return result;
		}
	}

	public function readInt(bits:Int = 32) {
		var value = 0;
		var shift = 0;
		while (bits > 0) {
			value |= readBits(bits < 8 ? bits : 8) << shift;
			shift += 8;
			bits -= 8;
		}
		return value;
	}

	public function readFlag() {
		return readInt(1) != 0;
	}

	public function readByte() {
		return readInt(8);
	}

	public function readUInt16() {
		return readInt(16);
	}

	public function readInt32() {
		return readInt(32);
	}

	public function readRangedU32(rangeStart:Int, rangeEnd:Int) {
		var rangeSize = rangeEnd - rangeStart + 1;
		var rangeBits = Util.getNextBinLog2(rangeSize);
		return rangeStart + readInt(rangeBits);
	}

	public function readFloat() {
		return FPHelper.i32ToFloat(readInt32());
	}

	public function readDouble() {
		var lo = readInt32();
		var hi = readInt32();
		return FPHelper.i64ToDouble(lo, hi);
	}

	public function readString() {
		var length = readUInt16();
		var str = "";
		var buf = new StringBuf();
		for (i in 0...length) {
			buf.addChar(readByte());
		}
		return buf.toString();
	}

	public function getBitPosition():Int {
		return (position << 3) + shift;
	}

	public function setBitPosition(pos:Int) {
		position = pos >> 3;
		shift = pos & 7;
	}

	public function advanceBitPosition(numBits:Int) {
		setBitPosition(getBitPosition() + numBits);
	}
}

class OutputBitStream {
	// Fixed-size buffer, like TNL's PacketStream (MaxPacketDataSize).
	// Writes are read-modify-write at an arbitrary bit position, which is what
	// makes setBitPosition/rewinding (un-writing an event) possible.
	public static inline var MaxPacketSize:Int = 1500;
	// pad so a write that overflows the packet cap can't run off the buffer
	static var BufferPad:Int = 8;

	var data:Bytes;
	var position:Int; // current byte index
	var shift:Int; // current bit offset within the byte (0-7)
	var endPosition:Int = MaxPacketSize; // max bytes allowed in the packet
	var error:Bool = false;

	public function new(packetSize:Int = MaxPacketSize) {
		data = Bytes.alloc(packetSize + BufferPad);
		endPosition = packetSize;
		position = 0;
		shift = 0;
	}

	public function getBitPosition():Int {
		return (position << 3) + shift;
	}

	public function setBitPosition(newBitPosition:Int) {
		position = newBitPosition >> 3;
		shift = newBitPosition & 7;
	}

	public function advanceBitPosition(numBits:Int) {
		setBitPosition(getBitPosition() + numBits);
	}

	public function getBytePosition():Int {
		return (getBitPosition() + 7) >> 3;
	}

	public function clearError() {
		error = false;
	}

	public function isValid():Bool {
		return !error;
	}

	// write bits (1..8) at the current bit position, preserving surrounding bits
	function writeBits(value:Int, bits:Int) {
		if (bits <= 0)
			return;
		value = value & (0xFF >> (8 - bits));

		if (getBitPosition() + bits > (endPosition << 3))
			error = true; // keep going so rewind-based callers see consistent positions

		var upShift = shift;
		var downShift = 8 - upShift;

		if (downShift >= bits) {
			// fits entirely within the current byte
			if (position < data.length) {
				var mask = ((1 << bits) - 1) << upShift;
				var b = data.get(position);
				data.set(position, (b & ~mask) | ((value << upShift) & mask));
			}
		} else {
			// spans the current byte and the next
			if (position < data.length) {
				var firstMask = (0xFF << upShift) & 0xFF;
				var b = data.get(position);
				data.set(position, (b & ~firstMask) | ((value << upShift) & firstMask));
			}
			if (position + 1 < data.length) {
				var secondBits = bits - downShift;
				var secondMask = (1 << secondBits) - 1;
				var b2 = data.get(position + 1);
				data.set(position + 1, (b2 & ~secondMask) | ((value >> downShift) & secondMask));
			}
		}

		// advance the cursor
		shift += bits;
		position += shift >> 3;
		shift &= 7;
	}

	public function writeInt(value:Int, bits:Int = 32) {
		while (bits > 0) {
			this.writeBits(value & 0xFF, bits < 8 ? bits : 8);
			value >>= 8;
			bits -= 8;
		}
	}

	// returns the value written, so callers can do: if (!bs.writeFlag(x)) ...
	public function writeFlag(value:Bool):Bool {
		writeInt(value ? 1 : 0, 1);
		return value;
	}

	// write at a specific bit position without disturbing the current position
	public function writeIntAt(value:Int, bits:Int, bitPosition:Int) {
		var curPos = getBitPosition();
		setBitPosition(bitPosition);
		writeInt(value, bits);
		setBitPosition(curPos);
	}

	public function writeByte(value:Int) {
		writeInt(value, 8);
	}

	public function writeUInt16(value:Int) {
		writeInt(value, 16);
	}

	public function writeInt32(value:Int) {
		writeInt(value, 32);
	}

	public function writeRangedU32(value:Int, rangeStart:Int, rangeEnd:Int) {
		var rangeSize = rangeEnd - rangeStart + 1;
		var rangeBits = Util.getNextBinLog2(rangeSize);
		writeInt(value - rangeStart, rangeBits);
	}

	public function getBytes():Bytes {
		var byteLen = getBytePosition();
		if (byteLen > endPosition)
			byteLen = endPosition;
		if (byteLen > data.length)
			byteLen = data.length;
		return data.sub(0, byteLen);
	}

	public function writeFloat(value:Float) {
		writeInt(FPHelper.floatToI32(value), 32);
	}

	public function isFull():Bool {
		return getBitPosition() > (endPosition << 3);
	}

	public function getBitSpaceAvailable():Int {
		return (endPosition << 3) - getBitPosition();
	}

	public function setEndPosition(pos:Int) {
		endPosition = pos;
	}

	public function writeString(value:String) {
		writeUInt16(value.length);
		for (i in 0...value.length) {
			writeByte(StringTools.fastCodeAt(value, i));
		}
	}

	public function writeDouble(value:Float) {
		var i64 = FPHelper.doubleToI64(value);
		writeInt32(i64.low);
		writeInt32(i64.high);
	}
}
