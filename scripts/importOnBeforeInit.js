import org.json.JSONObject;
var resp = jelastic.env.control.ExecCmdById('${env.envName}', session, '${nodes.cp.master.id}', toJSON([{ command: 'bash $HOME/migrator/migrator.sh getProjectList --format=json' }]), true);
var projectList = JSON.parse(resp.responses[0].out).projects;
var projectListPrepared = prepareProjects(projectList);
      
function prepareProjects(values) {
    var aResultValues = [];
    values = values || [];
    for (var i = 0, n = values.length; i < n; i++) {
        aResultValues.push({
            caption: values[i].siteUrl,
            value: values[i].id
        });
    }
    return aResultValues;
}

settings.fields.push({
  "caption": "Project",
  "type": "list",
  "tooltip": "Select the project which you want to import",          
  "name": "project",
  "required": false,
  "multiSelect": true,
  "values": projectListPrepared
})

return settings;
