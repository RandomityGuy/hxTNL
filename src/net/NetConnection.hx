package net;

import haxe.Int32;
import net.BitStream.OutputBitStream;
import haxe.io.BytesBuffer;
import net.BitStream.InputBitStream;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;
import datachannel.RTCDataChannel;
import datachannel.RTCPeerConnection;

enum ConnectionState {
	NotConnected;
	PerformingWebRTCHandshake;
	AwaitingConnectRequest;
	AwaitingConnectResponse;
	ConnectTimedOut;
	ConnectRejected;
	Connected;
	Disconnected;
	TimedOut;
}

enum TerminationReason {
	TimedOut;
	FailedConnectHandshake;
	RemoteRejectedConnection;
	RemoteDisconnectPacket;
	DuplicateConnectionAttempt;
	SelfDisconnect;
	Error;
}

enum abstract NetPacketType(Int) from Int to Int {
	var DataPacket;
	var PingPacket;
	var AckPacket;
	var InvalidPacket;
}

enum abstract HeaderConstants(Int) from Int to Int {
	var MaxPacketWindowSizeShift = 5; ///< Packet window size is 2^MaxPacketWindowSizeShift.
	var MaxPacketWindowSize = (1 << MaxPacketWindowSizeShift); ///< Maximum number of packets in the packet window.
	var PacketWindowMask = MaxPacketWindowSize - 1; ///< Mask for accessing the packet window.
	var MaxAckMaskSize = 1 << (MaxPacketWindowSizeShift - 5); ///< Each ack word can ack 32 packets.
	var MaxAckByteCount = MaxAckMaskSize << 2; ///< The maximum number of ack bytes sent in each packet.
	var SequenceNumberBitSize = 11; ///< Bit size of the send and sequence number.
	var SequenceNumberWindowSize = (1 << SequenceNumberBitSize); ///< Size of the send sequence number window.
	var SequenceNumberMask = -SequenceNumberWindowSize; ///< Mask used to reconstruct the full send sequence number of the packet from the partial sequence number sent.
	var AckSequenceNumberBitSize = 10; ///< Bit size of the ack receive sequence number.
	var AckSequenceNumberWindowSize = (1 << AckSequenceNumberBitSize); ///< Size of the ack receive sequence number window.
	var AckSequenceNumberMask = -AckSequenceNumberWindowSize; ///< Mask used to reconstruct the full ack receive sequence number of the packet from the partial sequence number sent.
	var PacketHeaderBitSize = 3 + AckSequenceNumberBitSize + SequenceNumberBitSize; ///< Size, in bits, of the packet header sequence number section
	var PacketHeaderByteSize = (PacketHeaderBitSize + 7) >> 3; ///< Size, in bytes, of the packet header sequence number information
	var PacketHeaderPadBits = (PacketHeaderByteSize << 3) - PacketHeaderBitSize; ///< Padding bits to get header bytes to align on a byte boundary, for encryption purposes.
}

@:allow(net.NetConnection)
class PacketNotify {
	var rateChanged:Bool;
	var sendTime:Float;

	public function new() {}
}

@:structInit
@:publicFields
class NetRate {
	var minPacketSendPeriod:Int;
	var minPacketRecvPeriod:Int;
	var maxSendBandwidth:Int;
	var maxRecvBandwidth:Int;
}

@:allow(net.NetInterface)
@:netClass(ClassConnection)
class NetConnection extends NetBase {
	public var connectionState:ConnectionState = NotConnected;
	public var connectSequence:Int;

	public var isHost:Bool;

	var connectSendCount = 0;
	var connectLastSendTime = 0.0;

	var peer:RTCPeerConnection;
	var dc:RTCDataChannel;

	// After connection
	var lastPacketRecvTime:Float = 0;
	var lastSeqRecvdAtSend:Array<Int>;
	var lastSeqRecvd:Int = 0;
	var highestAckedSeq:Int;
	var lastSendSeq:Int;
	var ackMask:Array<Int>;
	var lastRecvAckAck:Int;
	var initialSendSeq:Int;
	var initialRecvSeq:Int;
	var highestAckedSendTime:Float = 0;
	var pingTimeout:Float = 5;
	var pingRetryCount:Int = 10;

	// some stuff
	var lastUpdateTime:Float = 0;
	var roundTripTime:Float = 0;
	var sendDelayCredit:Float = 0;
	var localRate:NetRate;
	var remoteRate:NetRate;
	var localRateChanged:Bool = false;
	var currentPacketSendSize:Int = 0;
	var currentPacketSendPeriod:Int = 0;

	// timeouts
	var pingSendCount:Int = 0;

	var lastPingSendTime:Float = 0;

	var notifyPackets:haxe.ds.List<PacketNotify>;

	public dynamic function onConnectionClosed() {}

	public dynamic function onLocalDescription(desc:String) {}

	public function new() {
		connectSequence = Math.floor(haxe.Timer.stamp());
		initialSendSeq = Math.floor(Math.random() * 32768);
		localRate = {
			maxRecvBandwidth: 2500,
			maxSendBandwidth: 2500,
			minPacketRecvPeriod: 96,
			minPacketSendPeriod: 96
		};
		remoteRate = {
			maxRecvBandwidth: 2500,
			maxSendBandwidth: 2500,
			minPacketRecvPeriod: 96,
			minPacketSendPeriod: 96
		};
		localRateChanged = true;
		computeNegotiatedRate();

		lastSendSeq = 0;
		highestAckedSeq = 0;

		ackMask = [for (i in 0...MaxAckMaskSize) 0];
		lastSeqRecvdAtSend = [for (i in 0...MaxPacketWindowSize) 0];

		notifyPackets = new haxe.ds.List<PacketNotify>();
	}

	public function initialize(host:Bool) {
		isHost = host;

		peer = new RTCPeerConnection(NetInterface.iceServers, NetInterface.boundIp);

		var candidates = [];

		peer.onLocalCandidate = (c) -> {
			if (c != "")
				candidates.push('a=${c}');
		}
		peer.onStateChange = (s) -> {
			switch (s) {
				case RTC_CLOSED:
					connectionClosedEvt();
				default:
					{}
			}
		}

		connectionState = PerformingWebRTCHandshake;

		var sdpFinished = false;
		var finishSdp = () -> {
			if (sdpFinished)
				return;
			sdpFinished = true;
			if (peer == null)
				return;
			var sdpObj = StringTools.trim(peer.localDescription);
			sdpObj = sdpObj + '\r\n' + candidates.join('\r\n') + '\r\n';
			onLocalDescription(sdpObj);
		}

		peer.onGatheringStateChange = (s) -> {
			if (s == RTC_GATHERING_COMPLETE) {
				finishSdp();
			}
		}

		if (!host) {
			dc = peer.createDatachannelWithOptions("udp", true, 0, 600);

			dc.onClosed = () -> {
				connectionClosedEvt();
			}

			dc.onOpen = (name) -> {
				connectionState = AwaitingConnectRequest;
			}
			dc.onMessage = (msg) -> {
				@:privateAccess NetInterface.processPacket(this, msg);
			}
		} else {
			peer.onDataChannel = (udpdc) -> {
				dc = udpdc;
				connectionState = AwaitingConnectRequest;

				dc.onMessage = (msg) -> {
					@:privateAccess NetInterface.processPacket(this, msg);
				}
			}
		}
	}

	// Transfer all the stuff to the new class which is most likely to be a subclass
	// This function should ONLY be called by NetInterface and not by a user
	function transferOwnership(conn:NetConnection) {
		conn.connectionState = connectionState;
		conn.connectSequence = connectSequence;
		conn.isHost = isHost;
		conn.connectSendCount = connectSendCount;
		conn.connectLastSendTime = connectLastSendTime;
		conn.peer = peer;
		conn.dc = dc;

		if (conn.dc != null) {
			conn.dc.onMessage = (msg) -> {
				@:privateAccess NetInterface.processPacket(conn, msg);
			}
			conn.dc.onClosed = () -> {
				conn.connectionClosedEvt();
			}
			conn.dc.onOpen = (name) -> {
				connectionState = AwaitingConnectRequest;
			}
		}
	}

	public inline function setRemoteDescription(remoteDesc:String, type:String) {
		if (peer != null)
			peer.setRemoteDescription(remoteDesc, type);
	}

	function checkTimeout(t:Float) {
		if (!isHost)
			return false;
		if (lastPingSendTime == 0)
			lastPingSendTime = t;
		var timeout = pingTimeout;
		var timeoutCount = pingRetryCount;
		if ((t - lastPingSendTime) > timeout) {
			if (pingSendCount >= timeoutCount)
				return true;
			lastPingSendTime = t;
			pingSendCount++;
			sendPingPacket();
		}
		return false;
	}

	function checkPacketSend(force:Bool, curTime:Float) {
		var delay = currentPacketSendPeriod / 1000.0;
		if (!force) {
			if (curTime - lastUpdateTime + sendDelayCredit < delay)
				return;
			sendDelayCredit = curTime - (lastUpdateTime + delay - sendDelayCredit);
			if (sendDelayCredit > 1)
				sendDelayCredit = 1;
		}
		prepareWritePacket();
		if (windowFull() || !isDataToTransmit())
			return;

		var ob = new OutputBitStream();
		writeRawPacket(ob, DataPacket);
		send(ob.getBytes());
	}

	inline function windowFull() {
		return (lastSendSeq - highestAckedSeq >= (MaxPacketWindowSize - 2));
	}

	function isDataToTransmit() {
		return false;
	}

	function sendPingPacket() {
		trace("Send Ping");
		var bs = new OutputBitStream();
		writeRawPacket(bs, PingPacket);
		send(bs.getBytes());
	}

	function sendAckPacket() {
		trace("Send Ack");
		var bs = new OutputBitStream();
		writeRawPacket(bs, AckPacket);
		send(bs.getBytes());
	}

	function writePacketHeader(bs:OutputBitStream, packetType:NetPacketType) {
		var ackByteCount = ((lastSeqRecvd - lastRecvAckAck + 7) >> 3);
		if (packetType == DataPacket)
			lastSendSeq++;
		bs.writeInt(packetType, 2);
		bs.writeInt(lastSendSeq, 5); // write the first 5 bits of the send sequence
		bs.writeFlag(true); // high bit of first byte indicates this is a data packet.
		bs.writeInt(lastSendSeq >> 5, SequenceNumberBitSize - 5); // write the rest of the send sequence
		bs.writeInt(lastSeqRecvd, AckSequenceNumberBitSize);
		bs.writeInt(0, PacketHeaderPadBits);

		bs.writeRangedU32(ackByteCount, 0, MaxAckByteCount);
		var wordCount = (ackByteCount + 3) >> 2;
		for (i in 0...wordCount) {
			bs.writeInt(ackMask[i], i == wordCount - 1 ? (ackByteCount - (i * 4)) * 8 : 32);
		}

		var sendDelay = NetInterface.time() - lastPacketRecvTime;
		if (sendDelay > 2)
			sendDelay = 2;
		bs.writeInt(Math.floor(sendDelay * 1000) >> 3, 8);

		if (packetType == DataPacket)
			lastSeqRecvdAtSend[lastSendSeq & PacketWindowMask] = lastSeqRecvd;
	}

	function readPacketHeader(bs:InputBitStream) {
		var packetType = bs.readInt(2);
		var seqNum = bs.readInt(5);
		var isDataPacket = bs.readFlag();
		seqNum |= (bs.readInt(SequenceNumberBitSize - 5) << 5);
		var highestAck = bs.readInt(AckSequenceNumberBitSize);
		var padBits = bs.readInt(PacketHeaderPadBits);
		if (padBits != 0)
			return false;

		seqNum |= (lastSeqRecvd & SequenceNumberMask);
		if (seqNum < lastSeqRecvd)
			seqNum += SequenceNumberWindowSize;
		if (seqNum - lastSeqRecvd > (MaxPacketWindowSize - 1))
			return false;

		highestAck |= (highestAckedSeq & AckSequenceNumberMask);

		if (highestAck < highestAckedSeq)
			highestAck += AckSequenceNumberWindowSize;
		if (highestAck > lastSendSeq)
			return false;

		var ackByteCount = bs.readRangedU32(0, MaxAckByteCount);
		if (ackByteCount > (cast MaxAckByteCount) || packetType >= (cast InvalidPacket))
			return false;

		var ackMask = [];
		var ackWordCount = (ackByteCount + 3) >> 2;
		for (i in 0...ackWordCount)
			ackMask.push(bs.readInt(i == ackWordCount - 1 ? (ackByteCount - (i * 4)) * 8 : 32));

		var sendDelay = (bs.readInt(8) << 3) + 4;

		var ackMaskShift = seqNum - lastSeqRecvd;

		while (ackMaskShift > 32) {
			var i = MaxAckMaskSize - 1;
			while (i > 0) {
				this.ackMask[i] = this.ackMask[i - 1];
				i--;
			}
			this.ackMask[0] = 0;
			ackMaskShift -= 32;
		}

		var upShifted = packetType == DataPacket ? 1 : 0;

		for (i in 0...MaxAckMaskSize) {
			var nextShift = this.ackMask[i] >> (32 - ackMaskShift);
			this.ackMask[i] = (this.ackMask[i] << ackMaskShift) | upShifted;
			upShifted = nextShift;
		}

		var notifyCount = highestAck - highestAckedSeq;
		for (i in 0...notifyCount) {
			var notifyIndex = highestAckedSeq + i + 1;
			var ackMaskBit = (highestAck - notifyIndex) & 0x1F;
			var ackMaskWord = (highestAck - notifyIndex) >> 5;

			var transmitSuccess = (ackMask[ackMaskWord] & (1 << ackMaskBit)) != 0;
			highestAckedSendTime = 0;
			handleNotify(notifyIndex, transmitSuccess);

			if (highestAckedSendTime > 0) {
				var rttDelta = NetInterface.time() - (highestAckedSendTime + sendDelay);
				roundTripTime = roundTripTime * 0.9 + rttDelta * 0.1;
				if (roundTripTime < 0)
					roundTripTime = 0;
			}
			if (transmitSuccess)
				lastRecvAckAck = lastSeqRecvdAtSend[notifyIndex & PacketWindowMask];
		}
		if (seqNum - lastRecvAckAck > cast MaxPacketWindowSize)
			lastRecvAckAck = seqNum - cast MaxPacketWindowSize;

		highestAckedSeq = highestAck;

		// keepAlive
		lastPingSendTime = 0;
		pingSendCount = 0;

		var prevLastSequence = lastSeqRecvd;
		lastSeqRecvd = seqNum;

		if (packetType == PingPacket || (seqNum - lastRecvAckAck > (MaxPacketWindowSize >> 1))) {
			sendAckPacket();
		}

		return prevLastSequence != seqNum && packetType == DataPacket;
	}

	function writeRawPacket(bs:OutputBitStream, packetType:NetPacketType) {
		writePacketHeader(bs, packetType);
		if (packetType == DataPacket) {
			var note = allocNotify();
			notifyPackets.add(note);
			note.sendTime = NetInterface.time();

			writePacketRateInfo(bs, note);
			writePacket(bs, note);
		}
	}

	function readRawPacket(bs:InputBitStream) {
		if (readPacketHeader(bs)) {
			lastPacketRecvTime = NetInterface.time();
			readPacketRateInfo(bs);
			readPacket(bs);
		}
	}

	function handleNotify(seq:Int, recvd:Bool) {
		var note = notifyPackets.pop();
		if (note.rateChanged && !recvd)
			localRateChanged = true;
		if (recvd) {
			highestAckedSendTime = note.sendTime;
			packetReceived(note);
		} else {
			packetDropped(note);
		}
	}

	function packetReceived(note:PacketNotify) {
		trace('packet received');
	}

	function packetDropped(note:PacketNotify) {
		trace('packet dropped');
	}

	public function prepareWritePacket() {}

	function writePacketRateInfo(bs:OutputBitStream, note:PacketNotify) {
		note.rateChanged = localRateChanged;
		localRateChanged = false;
		bs.writeFlag(note.rateChanged);
		if (note.rateChanged) {
			bs.writeRangedU32(localRate.maxRecvBandwidth, 0, 65535);
			bs.writeRangedU32(localRate.maxSendBandwidth, 0, 65535);
			bs.writeRangedU32(localRate.minPacketRecvPeriod, 1, 2047);
			bs.writeRangedU32(localRate.minPacketSendPeriod, 1, 2047);
		}
	}

	function readPacketRateInfo(bs:InputBitStream) {
		if (bs.readFlag()) {
			remoteRate.maxRecvBandwidth = bs.readRangedU32(0, 65535);
			remoteRate.maxSendBandwidth = bs.readRangedU32(0, 65535);
			remoteRate.minPacketRecvPeriod = bs.readRangedU32(1, 2047);
			remoteRate.minPacketSendPeriod = bs.readRangedU32(1, 2047);
			computeNegotiatedRate();
		}
	}

	function computeNegotiatedRate() {
		currentPacketSendPeriod = cast Math.max(localRate.minPacketSendPeriod, remoteRate.minPacketRecvPeriod);
		var maxBandwidth = Math.min(localRate.maxSendBandwidth, remoteRate.maxRecvBandwidth);
		currentPacketSendSize = Math.floor(maxBandwidth * currentPacketSendPeriod * 0.001);
		if (currentPacketSendSize > 1500)
			currentPacketSendSize = 1500;
	}

	function connectionClosedEvt() {
		if (connectionState != Disconnected) {
			connectionState = Disconnected;
			onConnectionTerminated(Error, "Disconnected");
		}
	}

	public inline function getSequence() {
		return connectSequence;
	}

	public inline function send(bytes:haxe.io.Bytes) {
		if (dc != null)
			dc.sendBytes(bytes);
	}

	public function allocNotify() {
		return new PacketNotify();
	}

	public function writePacket(bs:OutputBitStream, note:PacketNotify) {}

	public function readPacket(bs:InputBitStream) {}

	public function writeConnectRequest(bytes:BytesOutput) {}

	// return string as error, else null
	public function readConnectRequest(bytes:BytesInput):String {
		return null;
	}

	public function writeConnectAccept(bytes:BytesOutput) {}

	// return string as error, else null
	public function readConnectAccept(bytes:BytesInput):String {
		return null;
	}

	public function onConnectTerminated(reason:TerminationReason, msg:String) {}

	public function onConnectionTerminated(reason:TerminationReason, msg:String) {}

	public function onConnectionEstablished() {
		trace("Connection established!");
	}
}
