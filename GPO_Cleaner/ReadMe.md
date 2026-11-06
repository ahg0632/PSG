# GP Output Cleaner
This program is meant to parse the **Administrative Template** section of the gp report from the following command.

`gpresult /scope:user /z > exampleUser.txt`
`gpresult /scope:computer /z > exampleComp.txt`

It is best to extract this section into its own txt after the output file. Unfortunately there is more manual work required. This program is not extraneously automated.

## How To
- Use IDE of choice
- Ensure C++17 or higher
- compile
- run by placing `.txt` file in the same directory as the output executable file
    - `main.exe something.txt`
- The program will only work with specific keywords found inside the source code