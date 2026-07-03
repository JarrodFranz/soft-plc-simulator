// Structured Text AST (Abstract Syntax Tree)
//
// Represents parsed Structured Text expressions and statements.

use serde::{Deserialize, Serialize};

/// Literal values in Structured Text.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum StLiteral {
    Bool(bool),
    Int(i64),
    Float(f64),
    String(String),
}

/// Binary operators in Structured Text.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum BinaryOp {
    // Arithmetic
    Add,
    Sub,
    Mul,
    Div,
    Mod,

    // Relational
    Equal,        // =
    NotEqual,     // <>
    LessThan,     // <
    GreaterThan,  // >
    LessOrEqual,  // <=
    GreaterOrEqual,// >=

    // Logical / Bitwise
    And,
    Or,
    Xor,
}

/// Unary operators in Structured Text.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum UnaryOp {
    Not,
    Negate,
}

/// Structured Text Expression.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum StExpr {
    Literal(StLiteral),
    Variable(String),
    Unary {
        op: UnaryOp,
        expr: Box<StExpr>,
    },
    Binary {
        op: BinaryOp,
        left: Box<StExpr>,
        right: Box<StExpr>,
    },
}

/// Structured Text Statement.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum StStatement {
    /// Assignment statement: `variable := expression;`
    Assignment {
        variable: String,
        expr: StExpr,
    },

    /// IF-THEN-ELSIF-ELSE statement.
    If {
        condition: StExpr,
        then_body: Vec<StStatement>,
        elsif_branches: Vec<(StExpr, Vec<StStatement>)>,
        else_body: Option<Vec<StStatement>>,
    },

    /// WHILE loop statement: `WHILE condition DO body END_WHILE;`
    While {
        condition: StExpr,
        body: Vec<StStatement>,
    },

    /// REPEAT loop statement: `REPEAT body UNTIL condition END_REPEAT;`
    Repeat {
        body: Vec<StStatement>,
        until_condition: StExpr,
    },

    /// FOR loop statement: `FOR var := start TO end BY step DO body END_FOR;`
    For {
        variable: String,
        start: StExpr,
        end: StExpr,
        step: Option<StExpr>,
        body: Vec<StStatement>,
    },

    /// Function block call: `TON_1(IN := Motor_Run, PT := 5000);`
    FbCall {
        name: String,
        inputs: Vec<(String, StExpr)>,
    },
}
