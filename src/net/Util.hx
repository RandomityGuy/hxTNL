package net;

class Util {
	public static inline function getNextBinLog2(n:Int) {
		var bits = 0;
		var v = n;
		if (v >= 65536) {
			v >>= 16;
			bits += 16;
		}
		if (v >= 256) {
			v >>= 8;
			bits += 8;
		}
		if (v >= 16) {
			v >>= 4;
			bits += 4;
		}
		if (v >= 4) {
			v >>= 2;
			bits += 2;
		}
		if (v >= 2) {
			v >>= 1;
			bits += 1;
		}
		if (v >= 1) {
			bits += 1;
		}
		return bits;
	}
}
