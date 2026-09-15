package net;

import net.NetEvent.GuaranteeType;
import net.BitStream.InputBitStream;
import net.BitStream.OutputBitStream;
import net.NetConnection.NetPacketType;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;
import net.NetConnection.PacketNotify;

@:publicFields
class EventPacketNotify extends PacketNotify {
	var events:Array<EventNote>;
}

@:publicFields
@:structInit
class EventNote {
	var event:NetEvent;
	var seqCount:Int;
}

@:netClass(ClassConnection)
class EventConnection extends NetConnection {
	public static inline var MinimumPaddingBits:Int = 128;

	var sendEventQueue:Array<EventNote> = [];
	var unorderedSendEventQueue:haxe.ds.List<EventNote>;
	var waitSeqEvents:Array<EventNote> = [];
	var notifyEventList:Array<EventNote> = [];

	var nextSendEventSeq:Int = 0;
	var nextRecvEventSeq:Int = 0;
	var lastAckedEventSeq:Int = -1;

	var eventClassCount:Int = 0;
	var eventClassBitSize:Int = 0;

	public function new() {
		super();
		unorderedSendEventQueue = new haxe.ds.List<EventNote>();
	}

	public override function writeConnectRequest(bytes:BytesOutput) {
		super.writeConnectRequest(bytes);
		bytes.writeInt16(NetClassDB.getNetClassCount(NetClassType.ClassEvent));
	}

	public override function readConnectRequest(bytes:BytesInput):String {
		var err = super.readConnectRequest(bytes);
		if (err != null)
			return err;

		var classCount = bytes.readInt16();
		var myCount = NetClassDB.getNetClassCount(NetClassType.ClassEvent);
		if (classCount <= myCount)
			eventClassCount = myCount;
		else {
			eventClassCount = classCount;
		}
		eventClassBitSize = Util.getNextBinLog2(eventClassCount);

		return null;
	}

	public override function writeConnectAccept(bytes:BytesOutput) {
		super.writeConnectAccept(bytes);
		bytes.writeInt16(eventClassCount);
	}

	public override function readConnectAccept(bytes:BytesInput):String {
		var err = super.readConnectAccept(bytes);
		if (err != null)
			return err;

		eventClassCount = bytes.readInt16();
		var myCount = NetClassDB.getNetClassCount(NetClassType.ClassEvent);

		if (eventClassCount > myCount)
			return "Remote has more events than this!";

		eventClassBitSize = Util.getNextBinLog2(eventClassCount);
		return null;
	}

	public override function allocNotify():PacketNotify {
		return new EventPacketNotify();
	}

	public override function packetDropped(note:PacketNotify) {
		super.packetDropped(note);

		var evt:EventPacketNotify = cast note;

		for (event in evt.events) {
			switch (event.event.guarantee) {
				case GuaranteedOrdered:
					// put it in the right place
					var found = false;
					for (i in 0...this.sendEventQueue.length) {
						if (this.sendEventQueue[i].seqCount >= event.seqCount) {
							this.sendEventQueue.insert(i, event);
							found = true;
							break;
						}
					}
					if (!found)
						this.sendEventQueue.push(event);
				case Guaranteed:
					unorderedSendEventQueue.push(event);
				case Unguaranteed:
					event.event.notifyDelivered(this, false);
			}
		}
	}

	public override function packetReceived(note:PacketNotify) {
		super.packetReceived(note);

		var evt:EventPacketNotify = cast note;

		for (event in evt.events) {
			if (event.event.guarantee != GuaranteedOrdered) {
				event.event.notifyDelivered(this, true);
			} else {
				var found = false;
				for (i in 0...this.notifyEventList.length) {
					if (this.notifyEventList[i].seqCount >= event.seqCount) {
						this.notifyEventList.insert(i, event);
						found = true;
						break;
					}
				}
				if (!found)
					this.notifyEventList.push(event);
			}
		}

		while (this.notifyEventList.length > 0 && this.notifyEventList[0].seqCount == this.lastAckedEventSeq + 1) {
			this.lastAckedEventSeq++;
			this.notifyEventList[0].event.notifyDelivered(this, true);
			this.notifyEventList.shift();
		}
	}

	public override function writePacket(bs:OutputBitStream, note:PacketNotify) {
		super.writePacket(bs, note);

		var evt:EventPacketNotify = cast note;
		var packQueue:Array<EventNote> = [];

		while (unorderedSendEventQueue.length > 0) {
			if (bs.isFull())
				break;

			// peek, don't pop -- only dequeue once we know the event fits
			var first = unorderedSendEventQueue.first();

			var start = bs.getBitPosition();
			bs.writeFlag(true);

			var classId = first.event.getClassRep().getClassId();
			bs.writeInt(classId, eventClassBitSize);

			first.event.pack(this, bs);

			if (bs.getBitSpaceAvailable() < MinimumPaddingBits) {
				// rewind to before the event, and break out of the loop:
				bs.setBitPosition(start - 1);
				bs.clearError();
				break;
			}

			// dequeue the event and add this event onto the packet queue
			unorderedSendEventQueue.pop();
			packQueue.push(first);
		}

		bs.writeFlag(false);

		var prevSeq = -2;

		while (sendEventQueue.length > 0) {
			if (bs.isFull())
				break;

			// if the event window is full, stop processing
			if (sendEventQueue[0].seqCount > lastAckedEventSeq + 126)
				break;

			var first = sendEventQueue[0];

			var eventStart = bs.getBitPosition();
			bs.writeFlag(true);

			if (!bs.writeFlag(first.seqCount == prevSeq + 1))
				bs.writeInt(first.seqCount & 0x7F, 7);
			prevSeq = first.seqCount;

			var start = bs.getBitPosition();

			var classId = first.event.getClassRep().getClassId();
			bs.writeInt(classId, eventClassBitSize);

			first.event.pack(this, bs);

			first.event.getClassRep().addInitialUpdate(bs.getBitPosition() - start);

			if (bs.getBitSpaceAvailable() < MinimumPaddingBits) {
				bs.setBitPosition(eventStart);
				bs.clearError();
				break;
			}

			sendEventQueue.shift();
			packQueue.push(first);
		}

		for (ev in packQueue)
			ev.event.notifySent(this);

		evt.events = packQueue;
		bs.writeFlag(false);
	}

	public override function readPacket(bs:InputBitStream) {
		super.readPacket(bs);

		var prevSeq = -2;
		var unguaranteedPhase = true;

		while (true) {
			var bit = bs.readFlag();
			if (unguaranteedPhase && !bit) {
				unguaranteedPhase = false;
				bit = bs.readFlag();
			}
			if (!unguaranteedPhase && !bit)
				break;

			var seq = -1;

			if (!unguaranteedPhase) {
				if (bs.readFlag())
					seq = (prevSeq + 1) & 0x7F;
				else
					seq = bs.readInt(7);
				prevSeq = seq;
			}

			var classId = bs.readInt(eventClassBitSize);
			if (classId >= eventClassCount) {
				return; // invalid packet
			}
			var evt:NetEvent = cast NetClassDB.construct(classId, ClassEvent);
			if (evt == null) {
				return; // invalid packet
			}

			if (evt.direction == DirUnset
				|| (evt.direction == DirServerToClient && isHost)
				|| (evt.direction == DirClientToServer && !isHost)) {
				return; // invalid packet
			}

			evt.unpack(this, bs);

			if (unguaranteedPhase) {
				if (connectionState == Connected)
					evt.process(this);
				continue;
			}
			seq |= (nextRecvEventSeq & ~0x7F);
			if (seq < nextRecvEventSeq)
				seq += 128;

			var note:EventNote = {
				event: evt,
				seqCount: seq
			};

			var found = false;
			for (i in 0...this.waitSeqEvents.length) {
				if (this.waitSeqEvents[i].seqCount >= note.seqCount) {
					if (this.waitSeqEvents[i].seqCount != note.seqCount) // dont do duplicates
						this.waitSeqEvents.insert(i, note);
					found = true;
					break;
				}
			}
			if (!found) {
				this.waitSeqEvents.push(note);
			}
		}

		while (waitSeqEvents.length > 0 && waitSeqEvents[0].seqCount == nextRecvEventSeq) {
			nextRecvEventSeq++;
			var evt = waitSeqEvents.shift();
			if (connectionState == Connected)
				evt.event.process(this);
		}
	}

	public function postNetEvent(event:NetEvent) {
		var cid = event.getClassRep().getClassId();
		if (cid >= eventClassCount && connectionState == Connected)
			return false;
		event.notifyPosted(this);

		var note:EventNote = {
			event: event,
			seqCount: event.guarantee == GuaranteedOrdered ? nextSendEventSeq : -1
		};

		if (event.guarantee == GuaranteedOrdered)
			nextSendEventSeq++;

		if (event.guarantee == GuaranteedOrdered) {
			sendEventQueue.push(note);
		} else {
			unorderedSendEventQueue.add(note);
		}

		return true;
	}

	public override function isDataToTransmit():Bool {
		return unorderedSendEventQueue.length > 0 || sendEventQueue.length > 0 || super.isDataToTransmit();
	}
}
