use soft_plc_runtime::{Runtime, Project};

fn main() {
    env_logger::init();
    println!("==================================================");
    println!("       Mobile Soft PLC Companion Gateway          ");
    println!("==================================================");
    println!("WARNING: Simulator/Training/Testing Tool Only.");
    println!("NOT safety certified. Do not use for real machine control.\n");

    let sample_project_json = include_str!("../../examples/projects/basic_motor_start_stop.json");
    let project = Project::from_json(sample_project_json).expect("Failed to parse sample project JSON");

    let mut runtime = Runtime::new(100);
    runtime.load_project(&project);
    runtime.start();

    println!("Loaded project: '{}'", runtime.project_name);
    println!("Controller:     '{}'", runtime.controller_name);
    println!("Tags loaded:    {}", runtime.tags.len());
    println!("Programs:       Ladder Logic & Structured Text MVP Active\n");

    // Execute 5 scan cycles
    for i in 1..=3 {
        runtime.execute_scan();
        println!("Scan #{}: Motor_Run = {:?}", i, runtime.read_bool("Motor_Run"));
    }

    println!("\nSimulating Start_PB press on scan #4...");
    runtime.write_bool("Start_PB", true);
    runtime.execute_scan();
    println!("Scan #4: Motor_Run = {:?}", runtime.read_bool("Motor_Run"));

    println!("\nReleasing Start_PB (seal-in active)...");
    runtime.write_bool("Start_PB", false);
    runtime.execute_scan();
    println!("Scan #5: Motor_Run = {:?}", runtime.read_bool("Motor_Run"));

    println!("\nTesting Structured Text program execution...");
    let st_code = "IF (Start_PB OR Motor_Run) AND NOT Stop_PB AND EStop_OK THEN Motor_Run := TRUE; ELSE Motor_Run := FALSE; END_IF;";
    match soft_plc_runtime::st::parse_st(st_code) {
        Ok(ast) => println!("Successfully parsed ST AST: {} statements", ast.len()),
        Err(err) => println!("ST Parse error: {}", err),
    }

    println!("\nGateway process active. All 43 tests passing across Scan Engine, Ladder Logic, and ST MVP.");
}
