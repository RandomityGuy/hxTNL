package net;

import net.NetObject.NetFlags;
import net.BitStream.InputBitStream;
import net.BitStream.OutputBitStream;
import net.NetConnection.PacketNotify;
import net.EventConnection.EventPacketNotify;

enum abstract GhostInfoFlags(Int) from Int to Int {
	var InScope = 1 << 0;
	var ScopeLocalAlways = 1 << 1;
	var NotYetGhosted = 1 << 2;
	var Ghosting = 1 << 3;
	var KillGhost = 1 << 4;
	var KillingGhost = 1 << 5;
	var NotAvailable = (NotYetGhosted | Ghosting | KillGhost | KillingGhost);
}

@:publicFields
@:structInit
class GhostInfo {
	var obj:NetObject;
	var connection:GhostConnection = null;
	var updateMask:Int;
	var lastUpdateChain:GhostRef = null;
	var flags:Int;
	var priority:Float;
	var index:Int;
	var arrayIndex:Int;
	var updateSkipCount:Int = 0;
}

enum abstract GhostConnectionConsts(Int) from Int to Int {
	var GhostIdBitSize = 10;
	var GhostLookupTableSizeShift = 10;
	var MaxGhostCount = 1 << GhostIdBitSize;
	var GhostCountBitSize = GhostIdBitSize + 1;
	var GhostLookupTableSize = 1 << GhostLookupTableSizeShift;
	var GhostLookupTableMask = GhostLookupTableSize - 1;
}

@:structInit
@:publicFields
class GhostRef {
	var mask:Int;
	var ghostInfoFlags:Int;
	var ghost:GhostInfo;
	var updateChain:GhostRef;
}

@:netClass(ClassEvent)
class GhostPacketNotify extends EventPacketNotify {
	var ghostList:Array<GhostRef>;
}

@:netClass(ClassConnection)
@:allow(net.NetObject)
class GhostConnection extends EventConnection {
	var ghostZeroUpdateIndex:Int = 0;
	var ghostFreeIndex:Int;
	var ghosting:Bool = false;
	var scoping:Bool = false;
	var ghostingSequence:Int = 0;
	var scopeObject:NetObject;
	var localGhosts:Array<NetObject>;
	var ghostArray:Array<GhostInfo>;
	var ghostRefs:Array<GhostInfo>;
	var ghostLookupTable:Map<NetObject, GhostInfo>;

	public function new() {
		super();
	}

	public function setGhostTo(ghostTo:Bool) {
		if (localGhosts != null && localGhosts.length != 0)
			return;
		if (ghostTo) {
			localGhosts = [];
			for (i in 0...MaxGhostCount)
				localGhosts.push(null);
		}
	}

	public function setGhostFrom(ghostFrom:Bool) {
		if (ghostArray != null && ghostArray.length != 0)
			return;
		if (ghostFrom) {
			ghostFreeIndex = ghostZeroUpdateIndex = 0;
			ghostArray = [];
			ghostRefs = [];
			ghostLookupTable = [];
			for (i in 0...MaxGhostCount) {
				ghostArray.push(null);
				ghostRefs.push({
					obj: null,
					index: i,
					flags: 0,
					updateMask: 0,
					priority: 0,
					arrayIndex: 0,
				});
			}
		}
	}

	public override function packetDropped(note:PacketNotify) {
		super.packetDropped(note);

		var notify:GhostPacketNotify = cast note;

		for (ref in notify.ghostList) {
			var updateFlags = ref.mask;
			var walk = ref.updateChain;
			while (walk != null && updateFlags != 0) {
				updateFlags &= ~walk.mask;
				walk = walk.updateChain;
			}

			if (updateFlags != 0) {
				if (ref.ghost.updateMask == 0) {
					ref.ghost.updateMask = updateFlags;
					ghostPushNonZero(ref.ghost);
				} else
					ref.ghost.updateMask |= updateFlags;
			}

			if (ref.ghost.lastUpdateChain == ref)
				ref.ghost.lastUpdateChain = null;

			if ((ref.ghostInfoFlags & Ghosting) != 0) {
				ref.ghost.flags |= NotYetGhosted;
				ref.ghost.flags &= ~Ghosting;
			} else if ((ref.ghostInfoFlags & KillingGhost) != 0) {
				ref.ghost.flags |= KillGhost;
				ref.ghost.flags &= ~KillingGhost;
			}
		}
	}

	public override function packetReceived(note:PacketNotify) {
		super.packetReceived(note);

		var notify:GhostPacketNotify = cast note;

		for (ref in notify.ghostList) {
			if (ref.ghost.lastUpdateChain == ref)
				ref.ghost.lastUpdateChain = null;

			if ((ref.ghostInfoFlags & Ghosting) != 0) {
				ref.ghost.flags &= ~Ghosting;
				if (ref.ghost.obj != null)
					ref.ghost.obj.onGhostAvailable(this);
			} else if ((ref.ghostInfoFlags & KillingGhost) != 0)
				freeGhostInfo(ref.ghost);
		}
	}

	public override function prepareWritePacket() {
		super.prepareWritePacket();

		if (!doesGhostFrom() && !ghosting)
			return;

		for (i in 0...ghostZeroUpdateIndex) {
			var ghost = ghostArray[i];
			ghost.updateSkipCount++;
			if ((ghost.flags & ScopeLocalAlways) == 0)
				ghost.flags &= ~InScope;
		}

		if (scopeObject != null)
			scopeObject.performScopeQuery(this);
	}

	public override function isDataToTransmit():Bool {
		return super.isDataToTransmit() || ghostZeroUpdateIndex != 0;
	}

	public override function writePacket(bs:OutputBitStream, note:PacketNotify) {
		super.writePacket(bs, note);

		var notify:GhostPacketNotify = cast note;

		notify.ghostList = null;

		if (!doesGhostFrom())
			return;

		if (!bs.writeFlag(ghosting && scopeObject != null))
			return;

		var i = ghostZeroUpdateIndex - 1;
		while (i >= 0) {
			if ((ghostArray[i].flags & InScope) == 0)
				detachObject(ghostArray[i]);
			i--;
		}

		var maxIndex = 0;
		i = ghostZeroUpdateIndex - 1;
		while (i >= 0) {
			var walk = ghostArray[i];
			if (walk.index > maxIndex)
				maxIndex = walk.index;

			if ((walk.flags & KillGhost) != 0 && (walk.flags & NotYetGhosted) != 0) {
				freeGhostInfo(walk);
				i--;
				continue;
			} else if ((walk.flags & (KillingGhost | Ghosting)) == 0) {
				if ((walk.flags & KillGhost) != 0)
					walk.priority = 10000;
				else
					walk.priority = walk.obj.getUpdatePriority(scopeObject, walk.updateMask, walk.updateSkipCount);
			} else
				walk.priority = 0;
			i--;
		}

		var sorted = ghostArray.slice(0, ghostZeroUpdateIndex);
		sorted.sort((a, b) -> {
			var ret = a.priority = b.priority;
			return (ret < 0) ? -1 : ((ret > 0) ? 1 : 0);
		});
		for (i in 0...ghostZeroUpdateIndex)
			ghostArray[i] = sorted[i];

		i = ghostZeroUpdateIndex - 1;
		while (i >= 0) {
			ghostArray[i].arrayIndex = i;
			i--;
		}

		var sendSize = 1;
		while ((maxIndex >>= 1) != 0)
			sendSize++;
		if (sendSize < 3)
			sendSize = 3;

		bs.writeInt(sendSize - 3, 3);

		var updateList = [];

		var count = 0;
		i = ghostZeroUpdateIndex - 1;
		while (i >= 0 && !bs.isFull()) {
			var walk = ghostArray[i];
			if ((walk.flags & (KillingGhost | Ghosting)) != 0) {
				i--;
				continue;
			}

			var updateStart = bs.getBitPosition();
			var updateMask = walk.updateMask;
			var retMask = 0;

			bs.writeFlag(true);
			bs.writeInt(walk.index, sendSize);
			if (!bs.writeFlag((walk.flags & KillGhost) != 0)) {
				var startPos = bs.getBitPosition();
				if ((walk.flags & NotYetGhosted) != 0) {
					var classId = walk.obj.getClassRep().getClassId();
					bs.writeInt(classId, NetClassDB.getNetClassBitSize(ClassObject));
					NetObject.isInitialUpdate = true;
				}

				// update the object
				retMask = walk.obj.packUpdate(this, updateMask, bs);
				if (NetObject.isInitialUpdate) {
					NetObject.isInitialUpdate = false;
					walk.obj.getClassRep().addInitialUpdate(bs.getBitPosition() - startPos);
				} else
					walk.obj.getClassRep().addPartialUpdate(bs.getBitPosition() - startPos);
			}

			if (bs.getBitSpaceAvailable() < EventConnection.MinimumPaddingBits) {
				bs.setBitPosition(updateStart);
				bs.clearError();
				break;
			}

			var upd:GhostRef = {
				mask: 0,
				updateChain: null,
				ghost: walk,
				ghostInfoFlags: 0
			};

			updateList.push(upd);

			if ((walk.flags & KillGhost) != 0) {
				walk.flags &= ~KillGhost;
				walk.flags |= KillingGhost;
				walk.updateMask = 0;
				upd.mask = updateMask;
				ghostPushToZero(walk);
				upd.ghostInfoFlags = KillingGhost;
			} else {
				if ((walk.flags & NotYetGhosted) != 0) {
					walk.flags &= ~NotYetGhosted;
					walk.flags |= Ghosting;
					upd.ghostInfoFlags = Ghosting;
				}
				walk.updateMask = retMask;
				if (retMask == 0)
					ghostPushToZero(walk);
				upd.mask = updateMask & ~retMask;
				walk.updateSkipCount = 0;
				count++;
			}

			i--;
		}

		bs.writeFlag(false);
		notify.ghostList = updateList;
	}

	public override function readPacket(bs:InputBitStream) {
		super.readPacket(bs);

		if (!doesGhostTo())
			return;
		if (!bs.readFlag())
			return;

		var idSize = bs.readInt(3);
		idSize += 3;

		while (bs.readFlag()) {
			var idx = bs.readInt(idSize);
			if (bs.readFlag()) {
				if (localGhosts[idx] != null) {
					localGhosts[idx].onGhostRemove();
					localGhosts[idx] = null;
				}
			} else {
				if (localGhosts[idx] == null) {
					// new ghost!
					var classId = bs.readInt(NetClassDB.getNetClassBitSize(ClassObject));
					if (classId == -1) {
						return; // invalid packet
					}
					var obj:NetObject = cast NetClassDB.construct(classId, ClassObject);
					if (obj == null) {
						return; // invalid packet
					}
					obj.owningConnection = this;
					obj.netFlags = NetFlags.IsGhost;
					obj.netIndex = idx;
					localGhosts[idx] = obj;
					NetObject.isInitialUpdate = true;
					localGhosts[idx].unpackUpdate(this, bs);
					NetObject.isInitialUpdate = false;

					if (!obj.onGhostAdd(this)) {
						return;
					}
				} else {
					localGhosts[idx].unpackUpdate(this, bs);
				}
			}
		}
	}

	public inline function setScopeObject(obj:NetObject) {
		scopeObject = obj;
	}

	public function detachObject(info:GhostInfo) {
		info.flags |= KillGhost;
		if (info.updateMask == 0) {
			info.updateMask = 0xFFFFFFFF;
			ghostPushNonZero(info);
		}
		if (info.obj != null) {
			ghostLookupTable.remove(info.obj);
			info.obj = null;
		}
	}

	public inline function freeGhostInfo(ghost:GhostInfo) {
		if (ghost.arrayIndex < ghostZeroUpdateIndex) {
			ghost.updateMask = 0;
			ghostPushToZero(ghost);
		}
		ghostPushZeroToFree(ghost);
	}

	public function objectLocalScopeAlways(obj:NetObject) {
		if (!doesGhostFrom())
			return;
		objectInScope(obj);
		ghostLookupTable.get(obj).flags |= ScopeLocalAlways;
	}

	public function objectLocalClearAlways(obj:NetObject) {
		if (!doesGhostFrom())
			return;
		if (ghostLookupTable.exists(obj))
			ghostLookupTable.get(obj).flags &= ~ScopeLocalAlways;
	}

	public function objectInScope(obj:NetObject) {
		if (!scoping || !doesGhostFrom())
			return;
		if (!obj.isGhostable() || obj.isScopeLocal())
			return;
		if (ghostLookupTable.exists(obj)) {
			ghostLookupTable.get(obj).flags |= InScope;
			return;
		}

		if (ghostFreeIndex == MaxGhostCount)
			return;

		var gi = ghostArray[ghostFreeIndex];
		ghostPushFreeToZero(gi);
		gi.updateMask = 0xFFFFFFFF;
		ghostPushNonZero(gi);

		gi.flags = NotYetGhosted | InScope;
		gi.obj = obj;
		gi.lastUpdateChain = null;
		gi.updateSkipCount = 0;
		gi.connection = this;
		if (!ghostLookupTable.exists(obj))
			ghostLookupTable.set(obj, gi);
	}

	public function activateGhosting() {
		if (!doesGhostFrom())
			return;
		ghostingSequence++;
		for (i in 0...MaxGhostCount) {
			if (ghostRefs[i] == null)
				ghostRefs[i] = {
					obj: null,
					arrayIndex: i,
					index: 0,
					priority: 0,
					flags: 0,
					updateMask: 0,
				};
			ghostArray[i] = ghostRefs[i];
		}
		scoping = true;
		rpcStartGhosting(ghostingSequence);
	}

	@:rpc(DirAny, GuaranteedOrdered)
	public function rpcStartGhosting(sequence:Int) {
		if (!doesGhostTo()) {
			return;
		}
		onStartGhosting();
		rpcReadyForNormalGhosts(sequence);
	}

	@:rpc(DirAny, GuaranteedOrdered)
	public function rpcReadyForNormalGhosts(sequence:Int) {
		if (!doesGhostFrom()) {
			return;
		}
		if (sequence != ghostingSequence)
			return;
		ghosting = true;
	}

	@:rpc(DirAny, GuaranteedOrdered)
	public function rpcEndGhosting() {
		if (!doesGhostTo())
			return;
		deleteLocalGhosts();
		onEndGhosting();
	}

	public function deleteLocalGhosts() {
		if (localGhosts == null || localGhosts.length == 0)
			return;
		for (i in 0...MaxGhostCount) {
			if (localGhosts[i] != null) {
				localGhosts[i].onGhostRemove();
				localGhosts[i] = null;
			}
		}
		localGhosts = null;
	}

	public function clearGhostInfo() {
		for (pkt in notifyPackets) {
			var note:GhostPacketNotify = cast pkt;
			note.ghostList = null;
		}
		for (i in 0...MaxGhostCount) {
			if (ghostRefs[i] != null && ghostRefs[i].arrayIndex < ghostFreeIndex) {
				detachObject(ghostRefs[i]);
				ghostRefs[i].lastUpdateChain = null;
				freeGhostInfo(ghostRefs[i]);
			}
		}
	}

	public function resetGhosting() {
		if (!doesGhostFrom())
			return;
		ghosting = false;
		scoping = false;
		rpcEndGhosting();
		ghostingSequence++;
		clearGhostInfo();
	}

	public inline function resolveGhost(id:Int) {
		if (id == -1)
			return null;
		return localGhosts[id];
	}

	public inline function resolveGhostParent(id:Int) {
		return ghostRefs[id].obj;
	}

	public inline function doesGhostFrom() {
		return ghostArray != null && ghostArray.length != 0;
	}

	public inline function doesGhostTo() {
		return localGhosts != null && localGhosts.length != 0;
	}

	inline function ghostPushNonZero(info:GhostInfo) {
		if (info.arrayIndex != ghostZeroUpdateIndex) {
			ghostArray[ghostZeroUpdateIndex].arrayIndex = info.arrayIndex;
			ghostArray[info.arrayIndex] = ghostArray[ghostZeroUpdateIndex];
			ghostArray[ghostZeroUpdateIndex] = info;
			info.arrayIndex = ghostZeroUpdateIndex;
		}
		ghostZeroUpdateIndex++;
	}

	inline function ghostPushToZero(info:GhostInfo) {
		ghostZeroUpdateIndex--;
		if (info.arrayIndex != ghostZeroUpdateIndex) {
			ghostArray[ghostZeroUpdateIndex].arrayIndex = info.arrayIndex;
			ghostArray[info.arrayIndex] = ghostArray[ghostZeroUpdateIndex];
			ghostArray[ghostZeroUpdateIndex] = info;
			info.arrayIndex = ghostZeroUpdateIndex;
		}
	}

	inline function ghostPushZeroToFree(info:GhostInfo) {
		ghostFreeIndex--;
		if (info.arrayIndex != ghostFreeIndex) {
			ghostArray[ghostFreeIndex].arrayIndex = info.arrayIndex;
			ghostArray[info.arrayIndex] = ghostArray[ghostFreeIndex];
			ghostArray[ghostFreeIndex] = info;
			info.arrayIndex = ghostFreeIndex;
		}
	}

	inline function ghostPushFreeToZero(info:GhostInfo) {
		if (info.arrayIndex != ghostFreeIndex) {
			ghostArray[ghostFreeIndex].arrayIndex = info.arrayIndex;
			ghostArray[info.arrayIndex] = ghostArray[ghostFreeIndex];
			ghostArray[ghostFreeIndex] = info;
			info.arrayIndex = ghostFreeIndex;
		}
		ghostFreeIndex++;
	}

	public override function allocNotify():PacketNotify {
		return new GhostPacketNotify();
	}

	public function getGhostIndex(obj:NetObject) {
		if (obj == null)
			return -1;
		if (!doesGhostFrom())
			return obj.netIndex;
		if (ghostLookupTable.exists(obj))
			return ghostLookupTable.get(obj).index;
		return -1;
	}

	public function onStartGhosting() {}

	public function onEndGhosting() {}
}
