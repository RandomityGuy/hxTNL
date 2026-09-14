package net;

import net.BitStream.InputBitStream;
import net.BitStream.OutputBitStream;
import net.EventConnection;

enum abstract EventDirection(Int) from Int to Int {
	var DirUnset;
	var DirAny;
	var DirServerToClient;
	var DirClientToServer;
}

enum abstract GuaranteeType(Int) from Int to Int {
	var GuaranteedOrdered;
	var Guaranteed;
	var Unguaranteed;
}

@:allow(net.EventConnection)
@:allow(net.NetObject)
@:netClass(ClassEvent)
abstract class NetEvent extends NetBase {
	var direction:EventDirection;
	var guarantee:GuaranteeType;

	public function new(guaranteeType:GuaranteeType = GuaranteedOrdered, dir:EventDirection = DirUnset) {
		guarantee = guaranteeType;
		direction = dir;
	}

	public abstract function pack(conn:EventConnection, bs:OutputBitStream):Void;

	public abstract function unpack(conn:EventConnection, bs:InputBitStream):Void;

	public abstract function process(conn:EventConnection):Void;

	public function notifyPosted(conn:EventConnection) {};

	public function notifySent(conn:EventConnection) {};

	public function notifyDelivered(conn:EventConnection, madeIt:Bool) {};

	public inline function getEventDirection() {
		return direction;
	}
}
