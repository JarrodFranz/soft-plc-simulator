// Structured Text Lexer (Tokenizer)
//
// Converts a Structured Text source string into a sequence of tokens.

#[derive(Debug, Clone, PartialEq)]
pub enum Token {
    // Keywords
    If,
    Then,
    Elsif,
    Else,
    EndIf,
    While,
    Do,
    EndWhile,
    Repeat,
    Until,
    EndRepeat,
    For,
    To,
    By,
    EndFor,
    True,
    False,
    And,
    Or,
    Not,
    Xor,
    Mod,

    // Identifiers & Literals
    Identifier(String),
    IntLiteral(i64),
    FloatLiteral(f64),
    StringLiteral(String),

    // Symbols & Operators
    Assignment,     // :=
    Equal,          // =
    NotEqual,       // <>
    LessThan,       // <
    GreaterThan,    // >
    LessOrEqual,    // <=
    GreaterOrEqual, // >=
    Plus,           // +
    Minus,          // -
    Star,           // *
    Slash,          // /
    Semicolon,      // ;
    Colon,          // :
    Comma,          // ,
    LeftParen,      // (
    RightParen,     // )
    OutputAssign,   // =>
}

#[derive(Debug, Clone)]
pub struct Lexer<'a> {
    input: &'a str,
    chars: std::str::Chars<'a>,
    current_char: Option<char>,
}

impl<'a> Lexer<'a> {
    pub fn new(input: &'a str) -> Self {
        let mut chars = input.chars();
        let current_char = chars.next();
        Self {
            input,
            chars,
            current_char,
        }
    }

    fn advance(&mut self) {
        self.current_char = self.chars.next();
    }

    fn peek(&self) -> Option<char> {
        self.chars.clone().next()
    }

    fn skip_whitespace_and_comments(&mut self) {
        while let Some(ch) = self.current_char {
            if ch.is_whitespace() {
                self.advance();
            } else if ch == '/' && self.peek() == Some('/') {
                // Line comment
                while self.current_char.is_some() && self.current_char != Some('\n') {
                    self.advance();
                }
            } else if ch == '(' && self.peek() == Some('*') {
                // Block comment (* ... *)
                self.advance(); // consume '('
                self.advance(); // consume '*'
                while self.current_char.is_some() {
                    if self.current_char == Some('*') && self.peek() == Some(')') {
                        self.advance();
                        self.advance();
                        break;
                    }
                    self.advance();
                }
            } else {
                break;
            }
        }
    }

    pub fn tokenize(&mut self) -> Result<Vec<Token>, String> {
        let mut tokens = Vec::new();

        while self.current_char.is_some() {
            self.skip_whitespace_and_comments();

            let ch = match self.current_char {
                Some(c) => c,
                None => break,
            };

            match ch {
                ';' => {
                    tokens.push(Token::Semicolon);
                    self.advance();
                }
                ',' => {
                    tokens.push(Token::Comma);
                    self.advance();
                }
                '(' => {
                    tokens.push(Token::LeftParen);
                    self.advance();
                }
                ')' => {
                    tokens.push(Token::RightParen);
                    self.advance();
                }
                '+' => {
                    tokens.push(Token::Plus);
                    self.advance();
                }
                '-' => {
                    tokens.push(Token::Minus);
                    self.advance();
                }
                '*' => {
                    tokens.push(Token::Star);
                    self.advance();
                }
                '/' => {
                    tokens.push(Token::Slash);
                    self.advance();
                }
                ':' => {
                    if self.peek() == Some('=') {
                        self.advance();
                        self.advance();
                        tokens.push(Token::Assignment);
                    } else {
                        tokens.push(Token::Colon);
                        self.advance();
                    }
                }
                '=' => {
                    if self.peek() == Some('>') {
                        self.advance();
                        self.advance();
                        tokens.push(Token::OutputAssign);
                    } else {
                        tokens.push(Token::Equal);
                        self.advance();
                    }
                }
                '<' => {
                    if self.peek() == Some('>') {
                        self.advance();
                        self.advance();
                        tokens.push(Token::NotEqual);
                    } else if self.peek() == Some('=') {
                        self.advance();
                        self.advance();
                        tokens.push(Token::LessOrEqual);
                    } else {
                        tokens.push(Token::LessThan);
                        self.advance();
                    }
                }
                '>' => {
                    if self.peek() == Some('=') {
                        self.advance();
                        self.advance();
                        tokens.push(Token::GreaterOrEqual);
                    } else {
                        tokens.push(Token::GreaterThan);
                        self.advance();
                    }
                }
                '\'' | '"' => {
                    let quote = ch;
                    self.advance();
                    let mut s = String::new();
                    while let Some(c) = self.current_char {
                        if c == quote {
                            self.advance();
                            break;
                        }
                        s.push(c);
                        self.advance();
                    }
                    tokens.push(Token::StringLiteral(s));
                }
                c if c.is_digit(10) => {
                    let mut num_str = String::new();
                    let mut is_float = false;
                    while let Some(c) = self.current_char {
                        if c.is_digit(10) {
                            num_str.push(c);
                            self.advance();
                        } else if c == '.' && !is_float && self.peek().map_or(false, |next| next.is_digit(10)) {
                            is_float = true;
                            num_str.push(c);
                            self.advance();
                        } else {
                            break;
                        }
                    }

                    if is_float {
                        let val: f64 = num_str.parse().map_err(|e| format!("Invalid float: {}", e))?;
                        tokens.push(Token::FloatLiteral(val));
                    } else {
                        let val: i64 = num_str.parse().map_err(|e| format!("Invalid int: {}", e))?;
                        tokens.push(Token::IntLiteral(val));
                    }
                }
                c if c.is_alphabetic() || c == '_' => {
                    let mut ident = String::new();
                    while let Some(c) = self.current_char {
                        if c.is_alphanumeric() || c == '_' {
                            ident.push(c);
                            self.advance();
                        } else {
                            break;
                        }
                    }

                    let uppercase = ident.to_uppercase();
                    let token = match uppercase.as_str() {
                        "IF" => Token::If,
                        "THEN" => Token::Then,
                        "ELSIF" => Token::Elsif,
                        "ELSE" => Token::Else,
                        "END_IF" => Token::EndIf,
                        "WHILE" => Token::While,
                        "DO" => Token::Do,
                        "END_WHILE" => Token::EndWhile,
                        "REPEAT" => Token::Repeat,
                        "UNTIL" => Token::Until,
                        "END_REPEAT" => Token::EndRepeat,
                        "FOR" => Token::For,
                        "TO" => Token::To,
                        "BY" => Token::By,
                        "END_FOR" => Token::EndFor,
                        "TRUE" => Token::True,
                        "FALSE" => Token::False,
                        "AND" => Token::And,
                        "OR" => Token::Or,
                        "NOT" => Token::Not,
                        "XOR" => Token::Xor,
                        "MOD" => Token::Mod,
                        _ => Token::Identifier(ident),
                    };
                    tokens.push(token);
                }
                _ => {
                    return Err(format!("Unexpected character: '{}'", ch));
                }
            }
        }

        Ok(tokens)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_lexer_basic() {
        let code = "IF Start_PB AND NOT Stop_PB THEN Motor_Run := TRUE; END_IF;";
        let mut lexer = Lexer::new(code);
        let tokens = lexer.tokenize().expect("Failed to tokenize");

        assert_eq!(
            tokens,
            vec![
                Token::If,
                Token::Identifier("Start_PB".to_string()),
                Token::And,
                Token::Not,
                Token::Identifier("Stop_PB".to_string()),
                Token::Then,
                Token::Identifier("Motor_Run".to_string()),
                Token::Assignment,
                Token::True,
                Token::Semicolon,
                Token::EndIf,
                Token::Semicolon,
            ]
        );
    }
}
