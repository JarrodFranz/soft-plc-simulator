// Structured Text Parser
//
// Converts a stream of tokens into a Structured Text AST.

use crate::st::ast::*;
use crate::st::lexer::Token;

pub struct Parser {
    tokens: Vec<Token>,
    pos: usize,
}

impl Parser {
    pub fn new(tokens: Vec<Token>) -> Self {
        Self { tokens, pos: 0 }
    }

    fn peek(&self) -> Option<&Token> {
        self.tokens.get(self.pos)
    }

    fn advance(&mut self) -> Option<Token> {
        if self.pos < self.tokens.len() {
            let tok = self.tokens[self.pos].clone();
            self.pos += 1;
            Some(tok)
        } else {
            None
        }
    }

    fn expect(&mut self, expected: Token) -> Result<(), String> {
        if let Some(tok) = self.peek() {
            if *tok == expected {
                self.advance();
                Ok(())
            } else {
                Err(format!("Expected token {:?}, found {:?}", expected, tok))
            }
        } else {
            Err(format!("Expected token {:?}, found EOF", expected))
        }
    }

    pub fn parse_program(&mut self) -> Result<Vec<StStatement>, String> {
        let mut statements = Vec::new();
        while self.peek().is_some() {
            statements.push(self.parse_statement()?);
        }
        Ok(statements)
    }

    pub fn parse_statement(&mut self) -> Result<StStatement, String> {
        match self.peek() {
            Some(Token::If) => self.parse_if_statement(),
            Some(Token::While) => self.parse_while_statement(),
            Some(Token::Repeat) => self.parse_repeat_statement(),
            Some(Token::For) => self.parse_for_statement(),
            Some(Token::Identifier(_)) => self.parse_assignment_or_fbcall(),
            Some(tok) => Err(format!("Unexpected statement start token: {:?}", tok)),
            None => Err("Unexpected EOF while parsing statement".to_string()),
        }
    }

    fn parse_assignment_or_fbcall(&mut self) -> Result<StStatement, String> {
        let name = match self.advance() {
            Some(Token::Identifier(id)) => id,
            _ => unreachable!(),
        };

        match self.peek() {
            Some(Token::Assignment) => {
                self.advance(); // consume :=
                let expr = self.parse_expression()?;
                self.expect(Token::Semicolon)?;
                Ok(StStatement::Assignment { variable: name, expr })
            }
            Some(Token::LeftParen) => {
                self.advance(); // consume (
                let mut inputs = Vec::new();
                while self.peek() != Some(&Token::RightParen) && self.peek().is_some() {
                    let param_name = match self.advance() {
                        Some(Token::Identifier(id)) => id,
                        tok => return Err(format!("Expected parameter name, found {:?}", tok)),
                    };

                    if self.peek() == Some(&Token::Assignment) || self.peek() == Some(&Token::OutputAssign) {
                        self.advance();
                    }

                    let param_expr = self.parse_expression()?;
                    inputs.push((param_name, param_expr));

                    if self.peek() == Some(&Token::Comma) {
                        self.advance();
                    }
                }
                self.expect(Token::RightParen)?;
                self.expect(Token::Semicolon)?;
                Ok(StStatement::FbCall { name, inputs })
            }
            tok => Err(format!("Expected ':=' or '(' after identifier '{}', found {:?}", name, tok)),
        }
    }

    fn parse_if_statement(&mut self) -> Result<StStatement, String> {
        self.expect(Token::If)?;
        let condition = self.parse_expression()?;
        self.expect(Token::Then)?;

        let mut then_body = Vec::new();
        while self.peek().map_or(false, |t| !matches!(t, Token::Elsif | Token::Else | Token::EndIf)) {
            then_body.push(self.parse_statement()?);
        }

        let mut elsif_branches = Vec::new();
        while self.peek() == Some(&Token::Elsif) {
            self.advance(); // consume ELSIF
            let elsif_cond = self.parse_expression()?;
            self.expect(Token::Then)?;
            let mut elsif_body = Vec::new();
            while self.peek().map_or(false, |t| !matches!(t, Token::Elsif | Token::Else | Token::EndIf)) {
                elsif_body.push(self.parse_statement()?);
            }
            elsif_branches.push((elsif_cond, elsif_body));
        }

        let mut else_body = None;
        if self.peek() == Some(&Token::Else) {
            self.advance(); // consume ELSE
            let mut body = Vec::new();
            while self.peek() != Some(&Token::EndIf) && self.peek().is_some() {
                body.push(self.parse_statement()?);
            }
            else_body = Some(body);
        }

        self.expect(Token::EndIf)?;
        self.expect(Token::Semicolon)?;

        Ok(StStatement::If {
            condition,
            then_body,
            elsif_branches,
            else_body,
        })
    }

    fn parse_while_statement(&mut self) -> Result<StStatement, String> {
        self.expect(Token::While)?;
        let condition = self.parse_expression()?;
        self.expect(Token::Do)?;

        let mut body = Vec::new();
        while self.peek() != Some(&Token::EndWhile) && self.peek().is_some() {
            body.push(self.parse_statement()?);
        }

        self.expect(Token::EndWhile)?;
        self.expect(Token::Semicolon)?;

        Ok(StStatement::While { condition, body })
    }

    fn parse_repeat_statement(&mut self) -> Result<StStatement, String> {
        self.expect(Token::Repeat)?;

        let mut body = Vec::new();
        while self.peek() != Some(&Token::Until) && self.peek().is_some() {
            body.push(self.parse_statement()?);
        }

        self.expect(Token::Until)?;
        let until_condition = self.parse_expression()?;
        self.expect(Token::EndRepeat)?;
        self.expect(Token::Semicolon)?;

        Ok(StStatement::Repeat {
            body,
            until_condition,
        })
    }

    fn parse_for_statement(&mut self) -> Result<StStatement, String> {
        self.expect(Token::For)?;
        let variable = match self.advance() {
            Some(Token::Identifier(id)) => id,
            tok => return Err(format!("Expected loop variable in FOR statement, found {:?}", tok)),
        };

        self.expect(Token::Assignment)?;
        let start = self.parse_expression()?;
        self.expect(Token::To)?;
        let end = self.parse_expression()?;

        let mut step = None;
        if self.peek() == Some(&Token::By) {
            self.advance();
            step = Some(self.parse_expression()?);
        }

        self.expect(Token::Do)?;

        let mut body = Vec::new();
        while self.peek() != Some(&Token::EndFor) && self.peek().is_some() {
            body.push(self.parse_statement()?);
        }

        self.expect(Token::EndFor)?;
        self.expect(Token::Semicolon)?;

        Ok(StStatement::For {
            variable,
            start,
            end,
            step,
            body,
        })
    }

    // Operator precedence parser
    pub fn parse_expression(&mut self) -> Result<StExpr, String> {
        self.parse_or_expr()
    }

    fn parse_or_expr(&mut self) -> Result<StExpr, String> {
        let mut left = self.parse_and_expr()?;
        while self.peek() == Some(&Token::Or) || self.peek() == Some(&Token::Xor) {
            let op = match self.advance().unwrap() {
                Token::Or => BinaryOp::Or,
                Token::Xor => BinaryOp::Xor,
                _ => unreachable!(),
            };
            let right = self.parse_and_expr()?;
            left = StExpr::Binary {
                op,
                left: Box::new(left),
                right: Box::new(right),
            };
        }
        Ok(left)
    }

    fn parse_and_expr(&mut self) -> Result<StExpr, String> {
        let mut left = self.parse_relational_expr()?;
        while self.peek() == Some(&Token::And) {
            self.advance();
            let right = self.parse_relational_expr()?;
            left = StExpr::Binary {
                op: BinaryOp::And,
                left: Box::new(left),
                right: Box::new(right),
            };
        }
        Ok(left)
    }

    fn parse_relational_expr(&mut self) -> Result<StExpr, String> {
        let mut left = self.parse_additive_expr()?;
        if let Some(tok) = self.peek() {
            let op = match tok {
                Token::Equal => Some(BinaryOp::Equal),
                Token::NotEqual => Some(BinaryOp::NotEqual),
                Token::LessThan => Some(BinaryOp::LessThan),
                Token::GreaterThan => Some(BinaryOp::GreaterThan),
                Token::LessOrEqual => Some(BinaryOp::LessOrEqual),
                Token::GreaterOrEqual => Some(BinaryOp::GreaterOrEqual),
                _ => None,
            };

            if let Some(binary_op) = op {
                self.advance();
                let right = self.parse_additive_expr()?;
                left = StExpr::Binary {
                    op: binary_op,
                    left: Box::new(left),
                    right: Box::new(right),
                };
            }
        }
        Ok(left)
    }

    fn parse_additive_expr(&mut self) -> Result<StExpr, String> {
        let mut left = self.parse_multiplicative_expr()?;
        while self.peek() == Some(&Token::Plus) || self.peek() == Some(&Token::Minus) {
            let op = match self.advance().unwrap() {
                Token::Plus => BinaryOp::Add,
                Token::Minus => BinaryOp::Sub,
                _ => unreachable!(),
            };
            let right = self.parse_multiplicative_expr()?;
            left = StExpr::Binary {
                op,
                left: Box::new(left),
                right: Box::new(right),
            };
        }
        Ok(left)
    }

    fn parse_multiplicative_expr(&mut self) -> Result<StExpr, String> {
        let mut left = self.parse_unary_expr()?;
        while self.peek() == Some(&Token::Star) || self.peek() == Some(&Token::Slash) || self.peek() == Some(&Token::Mod) {
            let op = match self.advance().unwrap() {
                Token::Star => BinaryOp::Mul,
                Token::Slash => BinaryOp::Div,
                Token::Mod => BinaryOp::Mod,
                _ => unreachable!(),
            };
            let right = self.parse_unary_expr()?;
            left = StExpr::Binary {
                op,
                left: Box::new(left),
                right: Box::new(right),
            };
        }
        Ok(left)
    }

    fn parse_unary_expr(&mut self) -> Result<StExpr, String> {
        if self.peek() == Some(&Token::Not) {
            self.advance();
            let expr = self.parse_unary_expr()?;
            Ok(StExpr::Unary {
                op: UnaryOp::Not,
                expr: Box::new(expr),
            })
        } else if self.peek() == Some(&Token::Minus) {
            self.advance();
            let expr = self.parse_unary_expr()?;
            Ok(StExpr::Unary {
                op: UnaryOp::Negate,
                expr: Box::new(expr),
            })
        } else {
            self.parse_primary_expr()
        }
    }

    fn parse_primary_expr(&mut self) -> Result<StExpr, String> {
        match self.advance() {
            Some(Token::True) => Ok(StExpr::Literal(StLiteral::Bool(true))),
            Some(Token::False) => Ok(StExpr::Literal(StLiteral::Bool(false))),
            Some(Token::IntLiteral(val)) => Ok(StExpr::Literal(StLiteral::Int(val))),
            Some(Token::FloatLiteral(val)) => Ok(StExpr::Literal(StLiteral::Float(val))),
            Some(Token::StringLiteral(val)) => Ok(StExpr::Literal(StLiteral::String(val))),
            Some(Token::Identifier(id)) => Ok(StExpr::Variable(id)),
            Some(Token::LeftParen) => {
                let expr = self.parse_expression()?;
                self.expect(Token::RightParen)?;
                Ok(expr)
            }
            tok => Err(format!("Expected primary expression, found {:?}", tok)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::st::lexer::Lexer;

    #[test]
    fn test_parse_st_if_statement() {
        let code = "IF Start_PB AND NOT Stop_PB THEN Motor_Run := TRUE; END_IF;";
        let mut lexer = Lexer::new(code);
        let tokens = lexer.tokenize().unwrap();
        let mut parser = Parser::new(tokens);
        let stmts = parser.parse_program().unwrap();

        assert_eq!(stmts.len(), 1);
        match &stmts[0] {
            StStatement::If { condition, then_body, .. } => {
                assert_eq!(then_body.len(), 1);
                assert!(matches!(condition, StExpr::Binary { op: BinaryOp::And, .. }));
            }
            _ => panic!("Expected IF statement"),
        }
    }
}
