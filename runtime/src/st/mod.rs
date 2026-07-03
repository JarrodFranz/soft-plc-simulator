// Structured Text Engine Module
//
// Lexer, Parser, AST, and Interpreter for IEC 61131-3 Structured Text (ST).

pub mod ast;
pub mod lexer;
pub mod parser;
pub mod interpreter;

pub use ast::{StExpr, StStatement};
pub use lexer::Lexer;
pub use parser::Parser;
pub use interpreter::Interpreter;

/// Parse a raw Structured Text source string into a list of AST statements.
pub fn parse_st(source: &str) -> Result<Vec<StStatement>, String> {
    let mut lexer = Lexer::new(source);
    let tokens = lexer.tokenize()?;
    let mut parser = Parser::new(tokens);
    parser.parse_program()
}
