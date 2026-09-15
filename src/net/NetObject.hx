package net;

import net.GhostConnection.GhostInfoFlags;
import net.GhostConnection.GhostInfo;
import net.BitStream.InputBitStream;
import net.BitStream.OutputBitStream;

enum abstract NetFlags(Int) from Int to Int {
	var IsGhost = 1 << 1;
	var ScopeLocal = 1 << 2;
	var Ghostable = 1 << 3;
}

@:netClass(ClassObject)
@:allow(net.GhostConnection)
abstract class NetObject extends NetBase {
	var dirtyMaskBits:Int;
	var netIndex:Int;
	var serverObject:NetObject;
	var owningConnection:GhostConnection;
	var ghostInfos:Array<GhostInfo>;

	var netFlags:Int;

	static var isInitialUpdate = false;
	static var dirtyList:Map<NetObject, Bool> = [];

	public function remove() {
		for (g in ghostInfos)
			g.connection.detachObject(g);
		if (dirtyMaskBits != 0) {
			dirtyList.remove(this);
		}
	}

	public function setMaskBits(orMask:Int) {
		if (dirtyMaskBits == 0) {
			dirtyList.set(this, true);
		}
		dirtyMaskBits |= orMask;
	}

	public function clearMaskBits(orMask:Int) {
		if (dirtyMaskBits != 0) {
			dirtyMaskBits &= ~orMask;
			if (dirtyMaskBits == 0)
				dirtyList.remove(this);
		}
		for (ghost in ghostInfos) {
			if (ghost.updateMask != 0 && ghost.updateMask == orMask) {
				ghost.updateMask = 0;
				ghost.connection.ghostPushToZero(ghost);
			} else
				ghost.updateMask &= ~orMask;
		}
	}

	public static function collapseDirtyList() {
		for (obj => _ in dirtyList) {
			var orMask = obj.dirtyMaskBits;
			obj.dirtyMaskBits = 0;
			if (orMask != 0) {
				for (ghost in obj.ghostInfos) {
					if (ghost.updateMask == 0) {
						ghost.updateMask = orMask;
						ghost.connection.ghostPushNonZero(ghost);
					} else
						ghost.updateMask |= orMask;
				}
			}
		}
		dirtyList.clear();
	}

	public function onGhostAdd(gc:GhostConnection):Bool {
		return true;
	}

	public function onGhostRemove():Void {}

	public function onGhostAvailable(gc:GhostConnection):Void {}

	public function packUpdate(gc:GhostConnection, updateMask:Int, bs:OutputBitStream):Int {
		return 0;
	}

	public function unpackUpdate(gc:GhostConnection, bs:InputBitStream):Void {}

	public function performScopeQuery(gc:GhostConnection):Void {
		gc.objectInScope(this);
	}

	public function getUpdatePriority(scopeObject:NetObject, updateMask:Int, updateSkips:Int):Float {
		return updateSkips * 0.1;
	}

	public inline function isGhost() {
		return (netFlags & IsGhost) != 0;
	}

	public inline function isScopeLocal() {
		return (netFlags & ScopeLocal) != 0;
	}

	public inline function isGhostable() {
		return (netFlags & Ghostable) != 0;
	}

	public function postNetEvent(event:NetObjectRPCEvent) {
		if (isGhost())
			owningConnection.postNetEvent(event);
		else {
			for (info in ghostInfos)
				if ((info.flags & GhostInfoFlags.NotAvailable) == 0)
					info.connection.postNetEvent(event);
		}
	}
}
