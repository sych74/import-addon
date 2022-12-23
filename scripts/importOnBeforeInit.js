import org.json.JSONObject;
var projects = jelastic.env.control.ExecCmdById('${env.envName}', session, '${nodes.cp.master.id}', toJSON([{ command: 'bash /home/jelastic/migrator/migrator.sh getProjectList' }]), true).responses[0].out;
var projectList = toNative(new JSONObject(String(projects))).projects;
var projectListPrepared = prepareProjects(projectList);
      
function prepareProjects(values) {
    var aResultValues = [];
    values = values || [];
    for (var i = 0, n = values.length; i < n; i++) {
        aResultValues.push({
            caption: values[i],
            value: values[i]
        });
    }
    return aResultValues;
}

settings.fields.push({
  "caption": "Project",
  "type": "list",
  "tooltip": "Select the project which you want to import",          
  "name": "project",
  "required": true,
  "values": projectListPrepared
}, {
  "caption": "Deploy all projects",
  "type": "checkbox",
  "name": "isAllDeploy",
  "value": false,
  "disabled": false,
  "tooltip": "Deploy all projects."
})

return settings;
