package examplenet;

import net.BitStream.InputBitStream;
import net.BitStream.OutputBitStream;
import net.GhostConnection;
import h2d.col.Bounds;
import net.NetObject;
import net.NetClassDB;
import net.NetClassType;

@:netClass(ClassObject)
class Building extends NetObject {
	var game:TestGame;
	var rect:Bounds;

	var obj:h2d.Graphics;

	public function new() {
		rect = new Bounds();
		rect.x = Math.random();
		rect.y = Math.random();
		rect.xMax = rect.xMin + Math.random() * 0.1 + 0.025;
		rect.yMax = rect.yMin + Math.random() * 0.1 + 0.025;

		game = null;

		netFlags |= Ghostable;

		obj = new h2d.Graphics();
		obj.beginFill(0x0000FF);
		obj.drawRect(rect.x * ExampleMain.instance.s2d.width, rect.y * ExampleMain.instance.s2d.height, rect.width * ExampleMain.instance.s2d.width,
			rect.height * ExampleMain.instance.s2d.height);
		obj.endFill();
	}

	public override function remove() {
		super.remove();

		if (game == null)
			return;
		game.buildings.remove(this);
	}

	public function addToGame(game:TestGame) {
		game.buildings.push(this);
		this.game = game;
		this.game.scene.addChild(obj);
	}

	public override function onGhostAdd(gc:GhostConnection):Bool {
		addToGame(TestGame.instance);
		return super.onGhostAdd(gc);
	}

	public override function packUpdate(gc:GhostConnection, updateMask:Int, bs:OutputBitStream):Int {
		if (bs.writeFlag((updateMask & 1) != 0)) {
			bs.writeFloat(rect.xMin);
			bs.writeFloat(rect.yMin);
			bs.writeFloat(rect.xMax);
			bs.writeFloat(rect.yMax);
		}
		return 0;
	}

	public override function unpackUpdate(gc:GhostConnection, bs:InputBitStream) {
		if (bs.readFlag()) {
			rect = new Bounds();
			rect.xMin = bs.readFloat();
			rect.yMin = bs.readFloat();
			rect.xMax = bs.readFloat();
			rect.yMax = bs.readFloat();

			obj.clear();
			obj.beginFill(0x0000FF);
			obj.drawRect(rect.x * ExampleMain.instance.s2d.width, rect.y * ExampleMain.instance.s2d.height, rect.width * ExampleMain.instance.s2d.width,
				rect.height * ExampleMain.instance.s2d.height);
			obj.endFill();
		}
	}
}
