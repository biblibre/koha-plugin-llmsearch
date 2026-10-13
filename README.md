# Koha LLM Search

![animation of the plugin at work](llmsearch.gif?raw=true)

## Introduction
This plugin is a first attempt at creating a LLM search plugin.
The architecture idea is to have the LLM only do a "translation" between a users request in natural language to generate valid Koha search query url. 

For now, it adds a "Robot" button next to the Search button of the OPAC.
A click on that button opens a chat overlay.
Given every aspect of the configuration has been done, you can already use any LLM on Koha's OPAC!
The configuration need an API Key from any provider compatible with OpenAI API.
You could use Mistral or Ollama for example. I've used Mistral during my tests.
If you want to use another platform, you will need to provide the base url of your LLM service provider, and the model you'll want to use.
Those are kind "Expert-mode" configuration.

## Configuration
The LLM connection options (API key, model and base URL) are stored in a `config.ini` file (JSON format) in the plugin directory.
Copy `config.ini-example` to `config.ini` and fill in your values:

    {
        "api_key": "your-api-key",
        "model": "mistral-small-latest",
        "base_url": "https://api.mistral.ai/v1/chat/completions"
    }

The file is gitignored: the API key stays on the server and is never displayed in the plugin configuration page.
Those options are meant to be edited by the system administrator on the server, not from the Koha interface.

The only mandatory option is the API Key which you will need to obtain from an LLM provider.
I used Mistral which I found was a very qualitative and rather cheap offer.
The default model is mistral-small-latest and the default base URL is the Mistral api endpoint.

If you want to use another service (for example Ollama) you'll have to fill in the proper values in `config.ini`.

All other options (welcome message, system prompt, access restrictions, statistics) are configured from the plugin configuration page in Koha.

There is a default system prompt provided which will help Koha creates a search URL but you could as well customize the prompt to make it reply to any other requests such as library opening hours or give the assistant some knowledge about your circulation rules.

There are also a configuration option to only allow the chat to appear to connected users or any users.

If you choose "Only logged", you can also restrict to a list of patron's category.
You can provide the list of allowed categorycodes separated with space in the option.
For example if you want to give access to Staff (S) and Teachers (T), you will enter "S T".

And you can also choose rather to log your users usage of the LLM or not.

## A word about usage statistics

We made it possible to track LLM usage in two ways.
If enabled, for each users request the plugin will store those informations :
- Date and time of the request
- Patron category
- Branch
- Patron's date of birth
- Patron's date of enrollment at the library
- Fields sort1 and sort2
- The selected language for the OPAC
- How much tokens was sent to the LLM
- How much tokens was received to the LLM

This way Koha's administrators can make some usage stats such as "Are students actually using the LLM for their researchs?" or "Are people new to the library aware of this service?" or "How much tokens/credits has been used by users of library X in the last months?".
Users requests are not stored in Koha, neither the response from the LLM.

Another interesting statistic to get is "Are the links provided by the LLM actually clicked?"
To track this usage, the default prompt generates search-urls with a "fake" parameter like opac-search.pl?llm=1.
This allows to find out how many searchs are assisted by the LLM if you analyse your logs or use a javascript visitor tracking tool (such as Matomo).

## Disclaimer
Running this plugin in production can generate a lot of API calls to an LLM hosting external service.
Especially when available on your OPAC without authentication and visible to all users and bots from the internet.
This - CAN - lead to unexpected costs!

Make sure you know what you're doing, try in a test environment.
It is recommended to roughly evaluate the average number of visitors your OPAC receives each day (for example using Matomo) to evaluate the cost.

Also be aware that this plugin WILL forward your users query to an external service.
Depending on the provider, this one can be either or all of the following :
 - non-libre
 - expensive
 - ecologicaly unfriendly
 - biaised
 - use your patrons requests to train their model or sell the data.

Given patrons do not disclose personnal information in the chat, none will be sent to the external service by this plugin.
Be safe, have fun!
