import 'fbd_pins.dart';
import 'ld_exec.dart';
import 'project_model.dart';
import 'tag_resolver.dart';

/// Validates a candidate name for a NEW or RENAMED [FbDefinition].
///
/// The execution engine resolves a block/node's `type`/`blockType` against
/// `fbDefinitionFor` (see `fbd_exec.dart`, `ld_exec.dart`) either before or
/// instead of its own built-in dispatch, so an FB definition that reuses a
/// reserved name would silently shadow a struct, a builtin composite
/// (TIMER/COUNTER/SYSTEM), another FB, or a built-in FBD/LD block type
/// project-wide — never a crash, just silently wrong behavior everywhere that
/// name is used. This returns a user-facing reason [name] is unusable, or
/// null when it is a valid, non-colliding, non-empty identifier.
///
/// [excluding] is the FB being renamed (so it doesn't collide with its own
/// current name); pass null when creating a brand new FB.
String? fbNameValidationError(PlcProject p, String name, {FbDefinition? excluding}) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) {
    return 'Name cannot be empty';
  }
  final collidesWithOtherFb = p.fbDefinitions
      .any((fb) => !identical(fb, excluding) && fb.name == trimmed);
  if (collidesWithOtherFb) {
    return 'A function block named "$trimmed" already exists';
  }
  if (p.structDefs.any((s) => s.name == trimmed)) {
    return 'A struct type named "$trimmed" already exists';
  }
  if (builtinCompositeNames().contains(trimmed)) {
    return '"$trimmed" is a reserved built-in composite type';
  }
  if (kFbdBuiltinBlockTypes.contains(trimmed) || kLdBuiltinBlockTypes.contains(trimmed)) {
    return '"$trimmed" is a reserved built-in block type';
  }
  return null;
}

/// True if [name] would be accepted by [fbNameValidationError] (no reason
/// returned).
bool isValidFbName(PlcProject p, String name, {FbDefinition? excluding}) =>
    fbNameValidationError(p, name, excluding: excluding) == null;
