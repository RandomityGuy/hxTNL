package net;

import net.GhostConnection.GhostConnectionConsts;
import haxe.io.Bytes;
import net.BitStream.InputBitStream;
import net.BitStream.OutputBitStream;
import net.NetEvent.GuaranteeType;
import net.NetEvent.EventDirection;

@:netClass(ClassEvent)
class NetObjectRPCEvent extends RPCEvent {
	public var destObject:NetObject;

	public function new() {
		super();
	}

	public override function pack(conn:EventConnection, bs:OutputBitStream) {
		var ghostIndex = -1;
		var gc:GhostConnection = cast conn;
		if (destObject != null) {
			ghostIndex = gc.getGhostIndex(destObject);
		}
		if (bs.writeFlag(ghostIndex != -1)) {
			bs.writeInt(ghostIndex, GhostConnectionConsts.GhostIdBitSize);
			super.pack(conn, bs);
		}
	}

	public override function unpack(conn:EventConnection, bs:InputBitStream) {
		var gc:GhostConnection = cast conn;
		if (bs.readFlag()) {
			var ghostIndex = bs.readInt(GhostConnectionConsts.GhostIdBitSize);
			super.unpack(conn, bs);

			if (direction == DirServerToClient)
				destObject = gc.resolveGhost(ghostIndex);
			else
				destObject = gc.resolveGhostParent(ghostIndex);
		}
	}

	public override function process(conn:EventConnection) {
		var allowed = direction == DirAny;
		allowed = allowed && (direction == DirServerToClient && !conn.isHost || direction == DirClientToServer && conn.isHost);
		if (allowed) {
			var argStream = new InputBitStream(argData);

			destObject.performRPC(funcId, argStream);
		}
	}
}
