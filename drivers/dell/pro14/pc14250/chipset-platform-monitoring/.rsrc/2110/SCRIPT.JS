
function GoPage(file)
{
	window.location = file;
}

function SetPrimaryHover(name)
{
	document.getElementById(name).className="primary_hover";
}
	
function SetPrimaryNormal(name)
{
	document.getElementById(name).className="primary_up";
}

function SetSecondaryNormal(name)
{
	document.getElementById(name).className="secondary_up";
}

function SetSecondaryHover(name)
{
	document.getElementById(name).className="secondary_hover";
}
