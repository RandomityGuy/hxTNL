package net;

import haxe.io.Bytes;
import net.BitStream.InputBitStream;
import net.BitStream.OutputBitStream;
import net.NetEvent.GuaranteeType;
import net.NetEvent.EventDirection;

@:netClass(ClassEvent)
class RPCEvent extends NetEvent {
	public var classType:NetClassType;
	public var funcId:Int;

	public var argData:Bytes;

	public function new() {
		super(GuaranteedOrdered, DirUnset);
	}

	public function pack(conn:EventConnection, bs:OutputBitStream) {
		bs.writeInt(guarantee, 2);
		bs.writeInt(direction, 2);
		bs.writeInt(cast classType, 4);
		bs.writeInt(funcId, 16);
		bs.writeInt(argData.length, 16);
		for (i in 0...argData.length)
			bs.writeByte(argData.get(i));
	}

	public function unpack(conn:EventConnection, bs:InputBitStream) {
		guarantee = bs.readInt(2);
		direction = bs.readInt(2);
		classType = bs.readInt(4);
		funcId = bs.readInt(16);
		var byteLen = bs.readInt(16);
		argData = Bytes.alloc(byteLen);
		for (i in 0...byteLen)
			argData.set(i, bs.readByte());
	}

	public function process(conn:EventConnection) {
		var allowed = direction == DirAny;
		allowed = allowed && (direction == DirServerToClient && !conn.isHost || direction == DirClientToServer && conn.isHost);
		if (allowed) {
			var argStream = new InputBitStream(argData);
			conn.performRPC(funcId, argStream);
		}
	}
}
