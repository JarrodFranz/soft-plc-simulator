// Structured Text Interpreter
//
// Evaluates ST AST statements and expressions against the TagDatabase
// and active timers during scan execution.

use std::collections::HashMap;
use crate::st::ast::*;
use crate::tag::{TagDatabase, TagValue};
use crate::timer::TonTimer;

pub struct Interpreter<'a> {
    pub db: &'a mut TagDatabase,
    pub timers: &'a mut HashMap<String, TonTimer>,
    pub scan_time_ms: u64,
}

impl<'a> Interpreter<'a> {
    pub fn new(
        db: &'a mut TagDatabase,
        timers: &'a mut HashMap<String, TonTimer>,
        scan_time_ms: u64,
    ) -> Self {
        Self {
            db,
            timers,
            scan_time_ms,
        }
    }

    pub fn execute_statements(&mut self, statements: &[StStatement]) -> Result<(), String> {
        for stmt in statements {
            self.execute_statement(stmt)?;
        }
        Ok(())
    }

    pub fn execute_statement(&mut self, stmt: &StStatement) -> Result<(), String> {
        match stmt {
            StStatement::Assignment { variable, expr } => {
                let val = self.eval_expr(expr)?;
                match val {
                    TagValue::Bool(b) => self.db.write_bool(variable, b),
                    TagValue::Float64(f) => self.db.write_f64(variable, f),
                    TagValue::Int32(i) => {
                        if let Some(tag) = self.db.get_tag_mut(variable) {
                            tag.set_value(TagValue::Int32(i));
                        }
                    }
                    TagValue::String(s) => {
                        if let Some(tag) = self.db.get_tag_mut(variable) {
                            tag.set_value(TagValue::String(s));
                        }
                    }
                    _ => {
                        self.db.write_f64(variable, val.as_f64());
                    }
                }
            }
            StStatement::If {
                condition,
                then_body,
                elsif_branches,
                else_body,
            } => {
                if self.eval_expr(condition)?.as_bool() {
                    self.execute_statements(then_body)?;
                } else {
                    let mut handled = false;
                    for (elsif_cond, elsif_body) in elsif_branches {
                        if self.eval_expr(elsif_cond)?.as_bool() {
                            self.execute_statements(elsif_body)?;
                            handled = true;
                            break;
                        }
                    }
                    if !handled {
                        if let Some(else_stmts) = else_body {
                            self.execute_statements(else_stmts)?;
                        }
                    }
                }
            }
            StStatement::While { condition, body } => {
                let mut max_loop = 10000; // Guard against infinite loop
                while self.eval_expr(condition)?.as_bool() {
                    self.execute_statements(body)?;
                    max_loop -= 1;
                    if max_loop == 0 {
                        return Err("WHILE loop exceeded maximum iteration count (infinite loop guard)".to_string());
                    }
                }
            }
            StStatement::Repeat { body, until_condition } => {
                let mut max_loop = 10000;
                loop {
                    self.execute_statements(body)?;
                    if self.eval_expr(until_condition)?.as_bool() {
                        break;
                    }
                    max_loop -= 1;
                    if max_loop == 0 {
                        return Err("REPEAT loop exceeded maximum iteration count".to_string());
                    }
                }
            }
            StStatement::For {
                variable,
                start,
                end,
                step,
                body,
            } => {
                let start_val = self.eval_expr(start)?.as_f64() as i64;
                let end_val = self.eval_expr(end)?.as_f64() as i64;
                let step_val = match step {
                    Some(s) => self.eval_expr(s)?.as_f64() as i64,
                    None => 1,
                };

                let mut current = start_val;
                let mut max_loop = 10000;
                while if step_val > 0 { current <= end_val } else { current >= end_val } {
                    if let Some(tag) = self.db.get_tag_mut(variable) {
                        tag.set_value(TagValue::Int32(current as i32));
                    }
                    self.execute_statements(body)?;
                    current += step_val;
                    max_loop -= 1;
                    if max_loop == 0 {
                        return Err("FOR loop exceeded maximum iteration count".to_string());
                    }
                }
            }
            StStatement::FbCall { name, inputs } => {
                // Support standard TON timer FB call
                let mut in_val = false;
                let mut pt_val = 1000u64;

                for (param_name, param_expr) in inputs {
                    let uppercase_param = param_name.to_uppercase();
                    if uppercase_param == "IN" {
                        in_val = self.eval_expr(param_expr)?.as_bool();
                    } else if uppercase_param == "PT" {
                        pt_val = self.eval_expr(param_expr)?.as_f64() as u64;
                    }
                }

                let timer = self.timers.entry(name.clone()).or_insert_with(|| TonTimer::new(pt_val));
                timer.preset_ms = pt_val;
                timer.update(in_val, self.scan_time_ms);

                // Write output Q tag if present in database (e.g. TON_1.Q or TON_1_Q)
                let q_tag_name = format!("{}_Q", name);
                if self.db.get_tag(&q_tag_name).is_some() {
                    self.db.write_bool(&q_tag_name, timer.done);
                }
            }
        }
        Ok(())
    }

    pub fn eval_expr(&self, expr: &StExpr) -> Result<TagValue, String> {
        match expr {
            StExpr::Literal(lit) => Ok(match lit {
                StLiteral::Bool(b) => TagValue::Bool(*b),
                StLiteral::Int(i) => TagValue::Int32(*i as i32),
                StLiteral::Float(f) => TagValue::Float64(*f),
                StLiteral::String(s) => TagValue::String(s.clone()),
            }),
            StExpr::Variable(var) => {
                if let Some(tag) = self.db.get_tag(var) {
                    Ok(tag.effective_value().clone())
                } else {
                    // Check if timer Q status requested
                    Ok(TagValue::Bool(false))
                }
            }
            StExpr::Unary { op, expr } => {
                let val = self.eval_expr(expr)?;
                match op {
                    UnaryOp::Not => Ok(TagValue::Bool(!val.as_bool())),
                    UnaryOp::Negate => Ok(TagValue::Float64(-val.as_f64())),
                }
            }
            StExpr::Binary { op, left, right } => {
                let l_val = self.eval_expr(left)?;
                let r_val = self.eval_expr(right)?;

                match op {
                    BinaryOp::And => Ok(TagValue::Bool(l_val.as_bool() && r_val.as_bool())),
                    BinaryOp::Or => Ok(TagValue::Bool(l_val.as_bool() || r_val.as_bool())),
                    BinaryOp::Xor => Ok(TagValue::Bool(l_val.as_bool() ^ r_val.as_bool())),
                    BinaryOp::Equal => Ok(TagValue::Bool((l_val.as_f64() - r_val.as_f64()).abs() < f64::EPSILON && l_val.as_bool() == r_val.as_bool())),
                    BinaryOp::NotEqual => Ok(TagValue::Bool((l_val.as_f64() - r_val.as_f64()).abs() >= f64::EPSILON || l_val.as_bool() != r_val.as_bool())),
                    BinaryOp::LessThan => Ok(TagValue::Bool(l_val.as_f64() < r_val.as_f64())),
                    BinaryOp::GreaterThan => Ok(TagValue::Bool(l_val.as_f64() > r_val.as_f64())),
                    BinaryOp::LessOrEqual => Ok(TagValue::Bool(l_val.as_f64() <= r_val.as_f64())),
                    BinaryOp::GreaterOrEqual => Ok(TagValue::Bool(l_val.as_f64() >= r_val.as_f64())),
                    BinaryOp::Add => Ok(TagValue::Float64(l_val.as_f64() + r_val.as_f64())),
                    BinaryOp::Sub => Ok(TagValue::Float64(l_val.as_f64() - r_val.as_f64())),
                    BinaryOp::Mul => Ok(TagValue::Float64(l_val.as_f64() * r_val.as_f64())),
                    BinaryOp::Div => {
                        let r = r_val.as_f64();
                        if r.abs() < f64::EPSILON {
                            Err("Division by zero in ST expression".to_string())
                        } else {
                            Ok(TagValue::Float64(l_val.as_f64() / r))
                        }
                    }
                    BinaryOp::Mod => Ok(TagValue::Int32((l_val.as_f64() as i64 % r_val.as_f64() as i64) as i32)),
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::st::lexer::Lexer;
    use crate::st::parser::Parser;
    use crate::tag::{Tag, IoType};

    #[test]
    fn test_st_execution_motor_control() {
        let mut db = TagDatabase::new();
        db.add_tag(Tag::new_bool("Start_PB", "Inputs/Start_PB", IoType::SimulatedInput, "Start"));
        db.add_tag(Tag::new_bool("Stop_PB", "Inputs/Stop_PB", IoType::SimulatedInput, "Stop"));
        db.add_tag(Tag::new_bool("EStop_OK", "Inputs/EStop_OK", IoType::SimulatedInput, "EStop"));
        db.add_tag(Tag::new_bool("Overload_OK", "Inputs/Overload_OK", IoType::SimulatedInput, "Overload"));
        db.add_tag(Tag::new_bool("Motor_Run", "Outputs/Motor_Run", IoType::SimulatedOutput, "Motor"));

        db.write_bool("EStop_OK", true);
        db.write_bool("Overload_OK", true);
        db.write_bool("Start_PB", true);

        let code = r#"
            IF (Start_PB OR Motor_Run) AND NOT Stop_PB AND EStop_OK AND Overload_OK THEN
                Motor_Run := TRUE;
            ELSE
                Motor_Run := FALSE;
            END_IF;
        "#;

        let mut lexer = Lexer::new(code);
        let tokens = lexer.tokenize().unwrap();
        let mut parser = Parser::new(tokens);
        let stmts = parser.parse_program().unwrap();

        let mut timers = HashMap::new();
        let mut interp = Interpreter::new(&mut db, &mut timers, 100);
        interp.execute_statements(&stmts).unwrap();

        assert_eq!(interp.db.read_bool("Motor_Run"), true);
    }
}
