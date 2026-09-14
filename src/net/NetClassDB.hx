package net;

import net.NetClassType;

@:build(net.NetClassDBMacro.build())
class NetClassDB {
	public static function construct(id:Int, type:NetClassType) {
		if (classReps[type].exists(id))
			return classReps[type].get(id).create();
		return null;
	}

	public static inline function getNetClassCount(classType:NetClassType) {
		return classCounts.get(classType);
	}

	public static inline function getNetClassBitSize(classType:NetClassType) {
		return classBitCounts.get(classType);
	}
}
