
function GoPage(file)
{
	window.location = file;
}

function SetPrimaryHover(name)
{
	document.getElementById(name).className="button primary_hover";
}
	
function SetPrimaryNormal(name)
{
	document.getElementById(name).className="button primary_up";
}

function SetSecondaryNormal(name)
{
	document.getElementById(name).className="button secondary_up";
}

function SetSecondaryHover(name)
{
	document.getElementById(name).className="button secondary_hover";
}

