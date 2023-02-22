import org.json.JSONObject;
var resp = jelastic.env.control.ExecCmdById('${env.envName}', session, '${nodes.cp.master.id}', toJSON([{ command: 'cat /home/jelastic/migrator/wplist.json' }]), true);
var projectList = JSON.parse(resp.responses[0].out);
var projectListPrepared = prepareProjects(projectList);
      
function prepareProjects(values) {
    var aResultValues = [];
    values = values || [];
    for (var i = 0, n = values.length; i < n; i++) {
        aResultValues.push({
            caption: values[i].siteUrl,
            value: values[i].fullPath
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

if (projectListPrepared.length > 1) {
  settings.fields.push({
    "caption": "Migrate all projects to separate WordPress environments.",
    "type": "checkbox",
    "name": "isAllDeploy",
    "value": false,
    "disabled": false,
    "tooltip": "Migrate all projects to separate WordPress environments."
  })
}

return settings;
