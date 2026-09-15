package net;

import haxe.EnumTools;
import haxe.macro.Context;
import haxe.macro.Expr.Field;
import haxe.macro.Expr.TypePath;

class NetClassDBMacro {
	static var netClasses:Array<{klass:haxe.macro.Type.ClassType, classType:String, classId:Int}> = [];

	macro static public function build():Array<Field> {
		var fields = Context.getBuildFields();
		var classTypeMap = new Map();

		var classTypeMacros = [];
		for (i in 0...NetClassType.ClassCount) {
			classTypeMacros.push([]);
		}

		for (netClass in netClasses) {
			var path:Array<String> = netClass.klass.pack.concat([netClass.klass.name]);

			var classType = switch (netClass.classType) {
				case "ClassNone": NetClassType.ClassNone;
				case "ClassObject": NetClassType.ClassObject;
				case "ClassDataBlock": NetClassType.ClassDataBlock;
				case "ClassEvent": NetClassType.ClassEvent;
				case "ClassConnection": NetClassType.ClassConnection;
				case _: NetClassType.ClassCount;
			};

			var classId = netClass.classId;
			var constructorFn = macro new NetClassRep($p{path}, $v{netClass.klass.name}, $i{netClass.classType}, $v{classId});
			classTypeMacros[classType].push(macro $v{classId} => $e{constructorFn});

			if (!classTypeMap.exists(netClass.classType))
				classTypeMap.set(netClass.classType, 0);

			classTypeMap.set(netClass.classType, classTypeMap.get(netClass.classType) + 1);
		}

		// classReps = [[id => new NetClassRep(), ..], [..]]

		var macroClass = macro class {
			static var classReps:Array<Map<Int, NetClassRep>> = [];
			static var classCounts:Map<NetClassType, Int> = [];
			static var classBitCounts:Map<NetClassType, Int> = [];
		}

		var classConsField = macroClass.fields[0];

		switch (classConsField.kind) {
			case FVar(t, e):
				switch (e.expr) {
					case EArrayDecl(values):
						for (cons in classTypeMacros) {
							values.push(macro $a{cons});
						}
					case _:
						null;
				}
			case _:
				null;
		}

		var classCountsField = macroClass.fields[1];

		switch (classCountsField.kind) {
			case FVar(t, e):
				switch (e.expr) {
					case EArrayDecl(values):
						for (classTypeName => classTypeCount in classTypeMap) {
							values.push(macro $i{classTypeName} => $v{classTypeCount});
						}
					case _:
						null;
				}
			case _:
				null;
		}

		var classBitCountsField = macroClass.fields[2];

		switch (classBitCountsField.kind) {
			case FVar(t, e):
				switch (e.expr) {
					case EArrayDecl(values):
						for (classTypeName => classTypeCount in classTypeMap) {
							var b = Util.getNextBinLog2(classTypeCount);
							values.push(macro $i{classTypeName} => $v{b});
						}
					case _:
						null;
				}
			case _:
				null;
		}

		fields = fields.concat(macroClass.fields);

		return fields;
	}
}
