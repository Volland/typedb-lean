## Purpose

Maps Lean structures to TypeDB entity and relation types, so that programs can insert, read, update and delete typed objects and generate or verify the schema without writing TypeQL by hand.

## ADDED Requirements

### Requirement: Entity mapping
Deriving an entity mapping for a structure SHALL map it to a TypeDB entity type, by default the structure's name in kebab-case and overridable by an attribute on the structure, and its fields to owned attributes labelled by default with the field name in kebab-case. The mapping SHALL support required fields, `Option` fields (optional attributes) and one field marked as key.

#### Scenario: Insert and get by key
- **WHEN** an entity value is inserted and then fetched by its key
- **THEN** the fetched value equals the inserted one

#### Scenario: Missing key returns none
- **WHEN** an entity is fetched by a key that does not exist
- **THEN** the result is `none`

### Requirement: Multi-valued attributes
An array field SHALL map to an attribute owned with cardinality `0..`. Reading the entity SHALL return all of its values for that attribute.

#### Scenario: Tags round trip
- **WHEN** an entity with tags `#[a, b, c]` is inserted and fetched
- **THEN** the fetched value has the same three tags; their order is not significant

### Requirement: Relation mapping
Deriving a relation mapping SHALL map a structure to a TypeDB relation type, with fields marked as roles holding references to role players, and other fields as owned attributes. Several fields MAY share a role.

#### Scenario: Insert relation between entities
- **WHEN** a friendship relation is inserted between two entities referenced by key
- **THEN** querying the friendship of either entity returns the relation with both players

### Requirement: References by key or IID
A reference to a mapped type SHALL identify the instance either by its key value or by its IID. Inserting a mapped value SHALL return an IID reference to the new instance.

#### Scenario: Insert returns IID
- **WHEN** a keyless relation is inserted
- **THEN** the returned reference holds an IID that a later get-by-reference resolves to the same relation

#### Scenario: Key reference to missing instance
- **WHEN** a relation is inserted with a key reference that matches no instance
- **THEN** the operation fails with an error and nothing is inserted

### Requirement: Relations as role players
A role field SHALL be able to reference a relation, so that relations can play roles in other relations.

#### Scenario: Endorsement of a friendship
- **WHEN** an endorsement relation is inserted whose `endorsed` role references a friendship relation by IID
- **THEN** querying the endorsement returns that friendship as the player

### Requirement: Subtyping
A structure that extends a mapped structure SHALL map to a subtype of the parent's TypeDB type and SHALL inherit its attributes and key. Inserting it SHALL create an instance of the most specific type.

#### Scenario: Subtype instance is a parent instance
- **WHEN** an `Employee` (extending `Person`) is inserted
- **THEN** a query for all persons includes it, and fetching it as an employee returns the employee fields

### Requirement: Polymorphic decoding
Deriving a polymorphic decoder for an inductive type whose constructors wrap mapped structures SHALL decode each instance into the constructor of its most specific TypeDB type.

#### Scenario: Mixed person types
- **WHEN** the database holds one `person` and one `employee` and all persons are decoded into a sum type with `person` and `employee` constructors
- **THEN** each instance decodes into its own constructor, with all of its fields

### Requirement: Update and delete
The mapping SHALL provide updating a single attribute of an instance, which replaces the old value, and deleting an instance by reference.

#### Scenario: Update attribute
- **WHEN** a person's name is updated
- **THEN** fetching the person returns the new name and the old name attribute is no longer owned by the person

#### Scenario: Delete
- **WHEN** an entity is deleted by reference
- **THEN** fetching it returns `none`

### Requirement: Schema generation
The library SHALL produce a TypeQL `define` statement for a list of mapped types, covering attribute types with value types, entity and relation types, `sub`, `owns` with key and cardinality annotations, `relates` and `plays`. Running it SHALL create a schema the mappings work against.

#### Scenario: Golden define
- **WHEN** the define statement is generated for the example social schema
- **THEN** it equals the checked-in golden file

#### Scenario: Generated schema is accepted
- **WHEN** the generated define statement runs on an empty database
- **THEN** it succeeds and the CRUD scenarios pass against it

### Requirement: Schema verification
The library SHALL check a list of mapped types against a live database's schema and report each mismatch: missing type, missing owned attribute, wrong value type, missing role or wrong supertype.

#### Scenario: Drift is reported
- **WHEN** a mapping declares an attribute the database's type does not own
- **THEN** verification returns a schema mismatch naming the type and the attribute

#### Scenario: Matching schema passes
- **WHEN** verification runs against a schema created from the same mappings
- **THEN** it reports no mismatches
