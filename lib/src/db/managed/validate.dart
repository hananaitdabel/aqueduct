import 'package:aqueduct/aqueduct.dart';
import 'package:aqueduct/src/openapi/openapi.dart';


/// Types of operations [ManagedValidator]s will be triggered for.
enum ValidateOperation { update, insert }

class ValidatorError extends Error {
  final String message;
  ValidatorError(this.message);

  factory ValidatorError.empty(String name) {
    return new ValidatorError("Invalid input for Validator on ${name}"
        "Input collection must have at least one element");
  }

  factory ValidatorError.invalidProperty(String name, String reason) {
    return new ValidatorError(
        "Invalid input for Validator on ${name}." + reason);
  }
  factory ValidatorError.invalidInput(String name, String reason) {
    return new ValidatorError(
        "Invalid value passed to Validator for ${name}." + reason);
  }
}


/// Validates properties of [ManagedObject] before an insert or update [Query].
///
/// Instances of this type are created during [ManagedDataModel] compilation.

class ManagedValidator extends Validator {

    ManagedValidator(ManagedAttributeDescription attribute, Validate definition) : super(attribute.name, attribute.type.kind, definition);

  //todo: add custom validation back with operation parameter

  /// Executes all [Validate]s for [object].
  ///
  /// Validates the properties of [object] according to its declared validators. Validators
  /// are added to properties using [Validate] metadata. See [Validate].
  ///
  /// This method is invoked by [ManagedObject.validate]. Invoking this method directly will
  /// ignore any validations that occur by overriding [ManagedObject.validate] and should be avoided.
  ///
  /// Pass an empty list for [errors] to receive more details on any failed validations.
  static bool run(ManagedObject object, {ValidateOperation operation: ValidateOperation.insert, List<String> errors}) {
    errors ??= [];

    var valid = true;
    var validators = object.entity.validators;
    validators.forEach((validator) {
      if (!validator.definition.runOnInsert && operation == ValidateOperation.insert) {
        return;
      }

      if (!validator.definition.runOnUpdate && operation == ValidateOperation.update) {
        return;
      }

      if (validator.definition._builtinValidate == _BuiltinValidate.absent) {
        if (object.backing.contents.containsKey(validator.name)) {
          valid = false;

          errors.add("Value for '${validator.name}' may not be included "
              "for ${_errorStringForOperation(operation)}s.");
        }
      } else if (validator.definition._builtinValidate == _BuiltinValidate.present) {
        if (!object.backing.contents.containsKey(validator.name)) {
          valid = false;

          errors.add("Value for '${validator.name}' must be included "
              "for ${_errorStringForOperation(operation)}s.");
        }
      } else {
        var value = object.backing.contents[validator.name];
        if (value != null) {
          if (!validator.isValid(value, errors)) {
            valid = false;
          }
        }
      }
    });

    return valid;
  }

  static String _errorStringForOperation(ValidateOperation op) {
    switch (op) {
      case ValidateOperation.insert:
        return "insert";
      case ValidateOperation.update:
        return "update";
      default:
        return "unknown";
    }
  }

}


class Validator {
  /// Creates an instance of this type.
  ///
  /// Instances of this type are created by adding [Validate] metadata
  /// to [ManagedObject] properties.
  Validator(this.name, this.type, this.definition) {
    if (definition._builtinValidate != null) {
      _build();
    }
//    else {
//      _validationMethod = definition.validate;
//    }
    //todo: add custom validation functionality back:  _validationMethod = definition.validate;
  }

  ManagedPropertyType type;
  String name;
  bool _isExpectingStringType = false;
  bool _comparisonValuesAreDateTime = false;

  Comparable get _greaterThan =>
      _comparisonValuesAreDateTime
          ? _convertToDateTime(definition._greaterThan)
          : _greaterThan;

  Comparable get _greaterThanEqualTo =>
      _comparisonValuesAreDateTime
          ? _convertToDateTime(definition._greaterThanEqualTo)
          : _greaterThanEqualTo;

  Comparable get _equalTo =>
      _comparisonValuesAreDateTime
          ? _convertToDateTime(definition._equalTo)
          : _equalTo;

  Comparable get _lessThan =>
      _comparisonValuesAreDateTime
          ? _convertToDateTime(definition._lessThan)
          : _lessThan;

  Comparable get _lessThanEqualTo =>
      _comparisonValuesAreDateTime
          ? _convertToDateTime(definition._lessThanEqualTo)
          : _lessThanEqualTo;

  /// The metadata associated with this instance.
  final Validate definition;
  _BuiltinValidate get validationStrategy => definition._builtinValidate;
  _Validation _validationMethod;
  RegExp _regex;
  List<_Validation> _expressionValidations;
  List<dynamic> _options;

  bool isValid(dynamic value, List<String> errors) {
    if (_isExpectingStringType && value is! String) {
      throw new ValidatorError.invalidInput(name,
          "The value for '${name}' is invalid. It must be a string."
      );
    } else if (value is! Comparable) {
      throw new ValidatorError.invalidInput(name,
          "The value for '${name}' is invalid. It must be comparable."
      );
    }

    var input = validationStrategy == _BuiltinValidate.length
        ? value.length
        : value;

    return _validationMethod(input, errors);
  }

  void _build() {
    if (validationStrategy == _BuiltinValidate.regex) {
      if (type != ManagedPropertyType.string) {
        throw new ValidatorError.invalidProperty(
            name, "Property type for Validate.matches must be String");
      }
      _isExpectingStringType = true;
      _regex = new RegExp(definition._value);
      _validationMethod = _validateRegex;
    } else if (validationStrategy == _BuiltinValidate.comparison) {
      _buildComparisonExpressions();
      _validationMethod = _validateExpressions;
    } else if (validationStrategy == _BuiltinValidate.length) {
      if (type != ManagedPropertyType.string) {
        throw new ValidatorError.invalidProperty(
            name, "Property type for Validate.length must be String");
      }
      _isExpectingStringType = true;
      _comparisonValuesAreDateTime = true;
      _buildComparisonExpressions();
      _validationMethod = _validateExpressions;
    } else if (validationStrategy == _BuiltinValidate.oneOf) {
      if (definition._values.isEmpty) {
        throw new ValidatorError.invalidProperty(
            name, "Validate.oneOf must have at least one element");
      }
      if (definition._values.any((v) => !isAssignableWith(v, type))) {
        throw new ValidatorError.invalidProperty(
            name, "All elements of Validate.oneOf must be assignable to '${type}'");
      }
      _options = definition._values;
      _validationMethod = _validateOneOf;
    }
  }

  void _buildComparisonExpressions() {
    _expressionValidations = [];

    if (_greaterThan != null) {
      var comparisonValue = _convertToDateTime(definition._greaterThan);
      _expressionValidations
          .add((dynamic value, List<String> errors) {

        if (value.compareTo(comparisonValue) <= 0) {
          errors.add("The value for '${name}' is invalid. Must be greater than '$comparisonValue'.");
          return false;
        }
      });
    }

    if (_greaterThanEqualTo != null) {
      var comparisonValue = _convertToDateTime(definition._greaterThanEqualTo);
      _expressionValidations
          .add((dynamic value, List<String> errors) {

        if (value.compareTo(comparisonValue) < 0) {
          errors
              .add("The value for '${name}' is invalid. Must be greater than or equal to '$comparisonValue'.");
          return false;
        }
      });
    }

    if (_lessThan != null) {
      var comparisonValue = _convertToDateTime(definition._lessThan);
      _expressionValidations
          .add((dynamic value, List<String> errors) {

        if (value.compareTo(comparisonValue) >= 0) {
          errors.add("The value for '${name}' is invalid. Must be less than to '$comparisonValue'.");
          return false;
        }
      });
    }

    if (_lessThanEqualTo != null) {
      var comparisonValue = _convertToDateTime(definition._lessThanEqualTo);
      _expressionValidations
          .add((dynamic value, List<String> errors) {

        if (value.compareTo(comparisonValue) > 0) {
          errors.add("The value for '${name}' is invalid. Must be less than or equal to '$comparisonValue'.");
          return false;
        }
      });
    }

    if (_equalTo != null) {
      var comparisonValue = _convertToDateTime(definition._equalTo);
      _expressionValidations
          .add((dynamic value, List<String> errors) {

        if (value.compareTo(comparisonValue) != 0) {
          errors.add("The value for '${name}' is invalid. Must be equal to '$comparisonValue'.");
          return false;
        }
      });
    }
  }

  dynamic _convertToDateTime(dynamic inputValue) {
    if (type == ManagedPropertyType.datetime) {
      try {
        return DateTime.parse(inputValue);
      } on FormatException {
        throw new ValidatorError.invalidProperty(
            name, "'$inputValue' cannot be parsed as DateTime");
      }
    }

    return inputValue;
  }

  bool _validateRegex(dynamic value, List<String> errors) {
    if (!_regex.hasMatch(value)) {
      errors.add("The value for '${name}' is invalid. Must match pattern ${_regex.pattern}.");
      return false;
    }

    return true;
  }

  bool _validateExpressions(dynamic value, List<String> errors) {
    // If any are false, then this validation failed and this returns false. Otherwise none are false and this method returns true.
    return !_expressionValidations.any((expr) => expr(value, errors) == false);
  }

  bool _validateOneOf(dynamic value, List<String> errors) {
    if (_options.every((v) => value != v)) {
      errors.add(
          "The value for '${name}' is invalid. Must be one of: ${_options.map((v) => "'$v'").join(",")}.");
      return false;
    }

    return true;
  }

  bool isAssignableWith(dynamic dartValue, ManagedPropertyType kind) {
    if (dartValue == null) {
      return true;
    }
    switch (kind) {
      case ManagedPropertyType.integer:
        return dartValue is int;
      case ManagedPropertyType.bigInteger:
        return dartValue is int;
      case ManagedPropertyType.boolean:
        return dartValue is bool;
      case ManagedPropertyType.datetime:
        return dartValue is DateTime;
      case ManagedPropertyType.doublePrecision:
        return dartValue is double;
      case ManagedPropertyType.string:
        return dartValue is String;
      case ManagedPropertyType.map:
        return dartValue is Map;
      case ManagedPropertyType.list:
        return dartValue is List;
      case ManagedPropertyType.document:
        return dartValue is Document;
    }
    return false;
  }
}

/// Add as metadata to persistent properties to validate their values before insertion or updating.
///
/// When executing update or insert queries, any properties with this metadata will be validated
/// against the condition declared by this instance. Example:
///
///         class Person extends ManagedObject<_Person> implements _Person {}
///         class _Person {
///           @primaryKey
///           int id;
///
///           @Validate.length(greaterThan: 10)
///           String name;
///         }
///
/// Properties may have more than one metadata of this type. All validations must pass
/// for an insert or update to be valid.
///
/// By default, validations occur on update and insert queries. Constructors have arguments
/// for only running a validation on insert or update. See [runOnUpdate] and [runOnInsert].
///
/// This class may be subclassed to create custom validations. Subclasses must override [validate].
class Validate<T> {
  /// Invoke this constructor when creating custom subclasses.
  ///
  /// This constructor is used so that subclasses can pass [onUpdate] and [onInsert].
  /// Example:
  ///         class CustomValidate extends Validate<String> {
  ///           CustomValidate({bool onUpdate: true, bool onInsert: true})
  ///             : super(onUpdate: onUpdate, onInsert: onInsert);
  ///
  ///            bool validate(
  ///              ValidateOperation operation,
  ///              ManagedAttributeDescription property,
  ///              String value,
  ///              List<String> errors) {
  ///                return someCondition;
  ///            }
  ///         }
  const Validate({bool onUpdate: true, bool onInsert: true})
      : runOnUpdate = onUpdate,
        runOnInsert = onInsert,
        this._value = null,
        this._values = null,
        this._lessThan = null,
        this._lessThanEqualTo = null,
        this._greaterThan = null,
        this._greaterThanEqualTo = null,
        this._equalTo = null,
        _builtinValidate = null;

  const Validate._(
      {bool onUpdate: true,
        bool onInsert: true,
        _BuiltinValidate validator,
        dynamic value,
        List<dynamic> values,
        Comparable greaterThan,
        Comparable greaterThanEqualTo,
        Comparable equalTo,
        Comparable lessThan,
        Comparable lessThanEqualTo})
      : runOnUpdate = onUpdate,
        runOnInsert = onInsert,
        _builtinValidate = validator,
        this._value = value,
        this._values = values,
        this._greaterThan = greaterThan,
        this._greaterThanEqualTo = greaterThanEqualTo,
        this._equalTo = equalTo,
        this._lessThan = lessThan,
        this._lessThanEqualTo = lessThanEqualTo;

  /// A validator for matching an input String against a regular expression.
  ///
  /// Values passing through validators of this type must match a regular expression
  /// created by [pattern]. See [RegExp] in the Dart standard library for behavior.
  ///
  /// This validator is only valid for [String] properties.
  ///
  /// If [onUpdate] is true (the default), this validation is run on update queries.
  /// If [onInsert] is true (the default), this validation is run on insert queries.
  const Validate.matches(String pattern, {bool onUpdate: true, onInsert: true})
      : this._(value: pattern, onUpdate: onUpdate, onInsert: onInsert, validator: _BuiltinValidate.regex);

  /// A validator for comparing a value.
  ///
  /// Values passing through validators of this type must be [lessThan],
  /// [greaterThan], [lessThanEqualTo], [equalTo], or [greaterThanEqualTo
  /// to the value provided for each argument.
  ///
  /// Any argument not specified is not evaluated. A typical validator
  /// only uses one argument:
  ///
  ///         @Validate.compare(lessThan: 10.0)
  ///         double value;
  ///
  /// All provided arguments are evaluated. Therefore, the following
  /// requires an input value to be between 6 and 10:
  ///
  ///         @Validate.compare(greaterThanEqualTo: 6, lessThanEqualTo: 10)
  ///         int value;
  ///
  /// This validator can be used for [String], [double], [int] and [DateTime] properties.
  ///
  /// When creating a validator for [DateTime] properties, the value for an argument
  /// is a [String] that will be parsed by [DateTime.parse].
  ///
  ///       @Validate.compare(greaterThan: "2017-02-11T00:30:00Z")
  ///       DateTime date;
  ///
  /// If [onUpdate] is true (the default), this validation is run on update queries.
  /// If [onInsert] is true (the default), this validation is run on insert queries.
  const Validate.compare(
      {Comparable lessThan,
        Comparable greaterThan,
        Comparable equalTo,
        Comparable greaterThanEqualTo,
        Comparable lessThanEqualTo,
        bool onUpdate: true,
        onInsert: true})
      : this._(
      lessThan: lessThan,
      lessThanEqualTo: lessThanEqualTo,
      greaterThan: greaterThan,
      greaterThanEqualTo: greaterThanEqualTo,
      equalTo: equalTo,
      onUpdate: onUpdate,
      onInsert: onInsert,
      validator: _BuiltinValidate.comparison);

  /// A validator for validating the length of a [String].
  ///
  /// Values passing through validators of this type must a [String] with a length that is[lessThan],
  /// [greaterThan], [lessThanEqualTo], [equalTo], or [greaterThanEqualTo
  /// to the value provided for each argument.
  ///
  /// Any argument not specified is not evaluated. A typical validator
  /// only uses one argument:
  ///
  ///         @Validate.length(lessThan: 10)
  ///         String foo;
  ///
  /// All provided arguments are evaluated. Therefore, the following
  /// requires an input string to have a length to be between 6 and 10:
  ///
  ///         @Validate.length(greaterThanEqualTo: 6, lessThanEqualTo: 10)
  ///         String foo;
  ///
  /// If [onUpdate] is true (the default), this validation is run on update queries.
  /// If [onInsert] is true (the default), this validation is run on insert queries.
  const Validate.length(
      {int lessThan,
        int greaterThan,
        int equalTo,
        int greaterThanEqualTo,
        int lessThanEqualTo,
        bool onUpdate: true,
        onInsert: true})
      : this._(
      lessThan: lessThan,
      lessThanEqualTo: lessThanEqualTo,
      greaterThan: greaterThan,
      greaterThanEqualTo: greaterThanEqualTo,
      equalTo: equalTo,
      onUpdate: onUpdate,
      onInsert: onInsert,
      validator: _BuiltinValidate.length);

  /// A validator for ensuring a property always has a value when being inserted or updated.
  ///
  /// This metadata requires that a property must be set in [Query.values] before an update
  /// or insert. The value may be null, if the property's [Column.isNullable] allow it.
  ///
  /// If [onUpdate] is true (the default), this validation requires a property to be present for update queries.
  /// If [onInsert] is true (the default), this validation requires a property to be present for insert queries.
  const Validate.present({bool onUpdate: true, bool onInsert: true})
      : this._(onUpdate: onUpdate, onInsert: onInsert, validator: _BuiltinValidate.present);

  /// A validator for ensuring a property does not have a value when being inserted or updated.
  ///
  /// This metadata requires that a property must NOT be set in [Query.values] before an update
  /// or insert.
  ///
  /// This validation is used to restrict input during either an insert or update query. For example,
  /// a 'dateCreated' property would use this validator to ensure that property isn't set during an update.
  ///
  ///       @Validate.absent(onUpdate: true, onInsert: false)
  ///       DateTime dateCreated;
  ///
  /// If [onUpdate] is true (the default), this validation requires a property to be absent for update queries.
  /// If [onInsert] is true (the default), this validation requires a property to be absent for insert queries.
  const Validate.absent({bool onUpdate: true, bool onInsert: true})
      : this._(onUpdate: onUpdate, onInsert: onInsert, validator: _BuiltinValidate.absent);

  /// A validator for ensuring a value is one of a set of values.
  ///
  /// An input value must be one of [values].
  ///
  /// [values] must be homogenous - every value must be the same type -
  /// and the property with this metadata must also match the type
  /// of the objects in [values].
  ///
  ///         @Validate.oneOf(const ["A", "B", "C")
  ///         String foo;
  ///
  /// If [onUpdate] is true (the default), this validation is run on update queries.
  /// If [onInsert] is true (the default), this validation is run on insert queries.
  const Validate.oneOf(List<dynamic> values, {bool onUpdate: true, bool onInsert: true})
      : this._(values: values, onUpdate: onUpdate, onInsert: onInsert, validator: _BuiltinValidate.oneOf);

  /// Whether or not this validation is checked on update queries.
  final bool runOnUpdate;

  /// Whether or not this validation is checked on insert queries.
  final bool runOnInsert;

  final dynamic _value;
  final List<dynamic> _values;
  final Comparable _greaterThan;
  final Comparable _greaterThanEqualTo;
  final Comparable _equalTo;
  final Comparable _lessThan;
  final Comparable _lessThanEqualTo;
  final _BuiltinValidate _builtinValidate;

//  void readFromMap(Map<String, dynamic> map) {
//    _value = map['_value'];
//    _values = map['_values'];
//    _greaterThan = map['_greaterThan'];
//    _greaterThanEqualTo = map['_greaterThanEqualTo'];
//    _equalTo = map['_equalTo'];
//    _lessThan = map['_lessThan'];
//    _lessThanEqualTo = map['_lessThanEqualTo'];
//    _bultinValidate = _builtInValidateFromString(map['_builtInValidate']);
//  }

  Map<String, dynamic> asMap() {
    Map<String, dynamic> map = {
      "value": _value,
      "values": _values,
      "greaterThan": _greaterThan,
      "greaterThanEqualTo": _greaterThanEqualTo,
      "equalTo": _equalTo,
      "lessThan": _lessThan,
      "lessThanEqualTo": _lessThanEqualTo,
      "bultinValidate": _builtInValidateToString(_builtinValidate)
    };
    return map;
  }

  String _builtInValidateToString(_BuiltinValidate validate) {
    switch (validate) {
      case _BuiltinValidate.regex:
        return "regex";
      case _BuiltinValidate.comparison:
        return "comparison";
      case _BuiltinValidate.length:
        return "length";
      case _BuiltinValidate.oneOf:
        return "oneOf";
      case _BuiltinValidate.absent:
        return "absent";
      case _BuiltinValidate.present:
        return "present";
    }
  }

  _builtInValidateFromString(String string) {
    switch (string) {
      case "regex":
        return _BuiltinValidate.regex;
      case "comparison":
        return _BuiltinValidate.comparison;
      case "length":
        return _BuiltinValidate.length;
      case "oneOf":
        return _BuiltinValidate.oneOf;
      case "absent":
        return _BuiltinValidate.absent;
      case "present":
        return _BuiltinValidate.present;
    }
  }

  /// Custom validations override this method to provide validation behavior.
  ///
  /// This method returns true if and only if [value] passes its test.
  /// If validation fails, a description of the failure should be added to [errors].
  /// [errors] is guaranteed to be a valid [List] when this method is invoked during validation.
  ///
  /// This method is not run when [value] is null.
  ///
  /// The type of [value] will have already been type-checked prior to executing this method.
  ///
  /// Both [operation] and [property] are informational only. This method will only be invoked
  /// according to [runOnInsert] and [runOnUpdate], i.e., if this validator's
  ///  [runOnUpdate] is false, [operation] will never be [ValidateOperation.update].
  bool validate(ValidateOperation operation, ManagedAttributeDescription property, T value, List<String> errors) {
    return false;
  }

  /// Adds constraints to an [APISchemaObject] imposed by this validator.
  ///
  /// Used during documentation process. When creating custom validator subclasses, override this method
  /// to modify [object] for any constraints the validator imposes.
  void constrainSchemaObject(APIDocumentContext context, APISchemaObject object) {
    switch (_builtinValidate) {
      case _BuiltinValidate.regex:
        {
          object.pattern = _value;
        }
        break;
      case _BuiltinValidate.comparison:
        {
          if (_greaterThan is num) {
            object.exclusiveMinimum = true;
            object.minimum = _greaterThan;
          } else if (_greaterThanEqualTo is num) {
            object.exclusiveMinimum = false;
            object.minimum = _greaterThanEqualTo;
          }

          if (_lessThan is num) {
            object.exclusiveMaximum = true;
            object.maximum = _lessThan;
          } else if (_lessThanEqualTo is num) {
            object.exclusiveMaximum = false;
            object.maximum = _lessThanEqualTo;
          }
        }
        break;
      case _BuiltinValidate.length:
        {
          if (_equalTo != null) {
            object.maxLength = _equalTo;
            object.minLength = _equalTo;
          } else {
            if (_greaterThan is int) {
              object.minLength = 1 + _greaterThan;
            } else if (_greaterThanEqualTo is int) {
              object.minLength = _greaterThanEqualTo;
            }

            if (_lessThan is int) {
              object.maxLength = (-1) + _lessThan;
            } else if (_lessThanEqualTo != null) {
              object.maximum = _lessThanEqualTo;
            }
          }
        }
        break;
      case _BuiltinValidate.present:
        {}
        break;
      case _BuiltinValidate.absent:
        {}
        break;
      case _BuiltinValidate.oneOf:
        {
          object.enumerated = _values;
        }
        break;
    }
  }
}

typedef bool _Validation<T>(T value, List<String> errors);
enum _BuiltinValidate { regex, comparison, length, present, absent, oneOf }