package net;

class NetClassRep {
	static var classIdCounter = 0;

	var classType:NetClassType;
	var classId:Int;
	var className:String;

	var initialUpdateBitsUsed:Int = 0;
	var partialUpdateBitsUsed:Int = 0;
	var initialUpdateCount:Int = 0;
	var partialUpdateCount:Int = 0;

	var netClass:Class<NetBase>;

	public function new(klass:Class<NetBase>, cname:String, ctype:NetClassType, cid:Int) {
		className = cname;
		classType = ctype;
		classId = cid;
		netClass = klass;
	}

	public inline function getClassId() {
		return classId;
	}

	public inline function getClassName() {
		className;
	}

	public inline function addInitialUpdate(bitCount:Int) {
		initialUpdateCount++;
		initialUpdateBitsUsed += bitCount;
	}

	public inline function addPartialUpdate(bitCount:Int) {
		partialUpdateCount++;
		partialUpdateBitsUsed += bitCount;
	}

	public function create() {
		return Type.createInstance(netClass, []);
	}
}
