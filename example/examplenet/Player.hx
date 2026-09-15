package examplenet;

import net.BitStream.InputBitStream;
import net.BitStream.OutputBitStream;
import net.GhostConnection;
import h3d.Vector;
import net.NetObject;
import net.NetObjectRPCEvent;
import net.NetClassType;
import net.NetClassDB;
import net.RPCEvent;

enum abstract PlayerType(Int) from Int to Int {
	var TypeAI;
	var TypeAIDummy;
	var TypeClient;
	var TypeMyClient;
}

enum abstract PlayerMaskBits(Int) from Int to Int {
	var InitialMask = 1 << 0;
	var PositionMask = 1 << 1;
}

@:netClass(ClassObject)
@:publicFields
class Player extends NetObject {
	var startPos:Vector;
	var endPos:Vector;
	var renderPos:Vector;
	var t:Float;
	var tDelta:Float;
	var game:TestGame;

	var playerType:PlayerType;
	var obj:h2d.Graphics;

	public function new() {
		startPos = new Vector(Math.random(), Math.random(), 0);
		endPos = startPos.clone();
		renderPos = startPos.clone();

		t = 1.0;
		tDelta = 0;
		playerType = TypeClient;
		netFlags |= Ghostable;
		game = null;

		obj = new h2d.Graphics();
		obj.beginFill(0xFF0000);
		obj.drawCircle(0, 0, 20);
		obj.endFill();
	}

	public override function remove() {
		super.remove();

		if (game == null)
			return;

		game.players.remove(this);
	}

	public function addToGame(game:TestGame) {
		game.players.push(this);
		this.game = game;
		if (playerType == TypeMyClient) {
			game.clientPlayer = this;
			obj.clear();
			obj.beginFill(0x00FF00);
			obj.drawCircle(0, 0, 3);
			obj.endFill();
		}
		this.game.scene.addChild(obj);
	}

	public override function onGhostAdd(gc:GhostConnection):Bool {
		addToGame(TestGame.instance);
		return super.onGhostAdd(gc);
	}

	public override function performScopeQuery(gc:GhostConnection) {
		for (b in game.buildings)
			gc.objectInScope(b);

		for (p in game.players) {
			if (p.renderPos.distanceSq(renderPos) < 0.0625)
				gc.objectInScope(p);
		}
	}

	public override function packUpdate(gc:GhostConnection, updateMask:Int, bs:OutputBitStream):Int {
		if (bs.writeFlag((updateMask & InitialMask) != 0)) {
			if (bs.writeFlag(playerType != TypeAI)) {
				bs.writeFlag(gc.scopeObject == this);
			}
		}

		if (bs.writeFlag((updateMask & PositionMask) != 0)) {
			bs.writeFloat(startPos.x);
			bs.writeFloat(startPos.y);
			bs.writeFloat(endPos.x);
			bs.writeFloat(endPos.y);
			bs.writeFloat(t);
			bs.writeFloat(tDelta);
		}
		return 0;
	}

	public override function unpackUpdate(gc:GhostConnection, bs:InputBitStream) {
		if (bs.readFlag()) {
			if (bs.readFlag()) {
				if (bs.readFlag())
					playerType = TypeMyClient;
				else
					playerType = TypeClient;
			} else
				playerType = TypeAIDummy;
		}
		if (bs.readFlag()) {
			startPos.x = bs.readFloat();
			startPos.y = bs.readFloat();
			endPos.x = bs.readFloat();
			endPos.y = bs.readFloat();
			t = bs.readFloat();
			tDelta = bs.readFloat();
			update(0);
		}
	}

	public function serverSetPosition(inStartPos:Vector, inEndPos:Vector, inT:Float, inTDelta:Float) {
		startPos.load(inStartPos);
		endPos.load(inEndPos);
		t = inT;
		tDelta = inTDelta;
		setMaskBits(PositionMask);
		rpcPlayerDidMove(inEndPos.x, inEndPos.y);
	}

	public function update(timeDelta:Float) {
		t += tDelta * timeDelta;
		if (t >= 1.0) {
			t = 1.0;
			tDelta = 0;
			renderPos.load(endPos);
			if (playerType == TypeAI) {
				startPos.load(renderPos);
				t = 0;
				endPos = new Vector(Math.random(), Math.random(), 0);
				tDelta = 0.2 + Math.random() * 0.1;
				setMaskBits(PositionMask);
			}
		}
		renderPos.load(startPos.add(endPos.sub(startPos).multiply(t)));
		obj.setPosition(renderPos.x * ExampleMain.instance.s2d.width, renderPos.y * ExampleMain.instance.s2d.height);
	}

	public override function onGhostAvailable(gc:GhostConnection) {
		super.onGhostAvailable(gc);

		rpcPlayerIsInScope(renderPos.x, renderPos.y);
	}

	@:rpc(DirServerToClient, GuaranteedOrdered)
	public function rpcPlayerIsInScope(x:Float, y:Float) {
		trace('A player is now in scope at ${x}, ${y}');
	}

	@:rpc(DirClientToServer, GuaranteedOrdered)
	public function rpcPlayerWillMove(testString:String) {
		trace('Expecting a player move from the connection: ${testString}');
	}

	@:rpc(DirServerToClient, GuaranteedOrdered)
	public function rpcPlayerDidMove(x:Float, y:Float) {
		trace('A player moved to ${x}, ${y}');
	}
}
