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
    println!("Running 5 initial scan cycles...\n");

    // Execute 5 scan cycles
    for i in 1..=5 {
        runtime.execute_scan();
        println!("Scan #{}: Motor_Run = {:?}", i, runtime.read_bool("Motor_Run"));
    }

    println!("\nSimulating Start_PB press on scan #6...");
    runtime.write_bool("Start_PB", true);
    runtime.execute_scan();
    println!("Scan #6: Motor_Run = {:?}", runtime.read_bool("Motor_Run"));

    println!("\nReleasing Start_PB (seal-in active)...");
    runtime.write_bool("Start_PB", false);
    runtime.execute_scan();
    println!("Scan #7: Motor_Run = {:?}", runtime.read_bool("Motor_Run"));

    println!("\nGateway process scaffold active. Protocol adapters (OPC UA, Modbus TCP, MQTT, DNP3) ready for phase deployment.");
}
