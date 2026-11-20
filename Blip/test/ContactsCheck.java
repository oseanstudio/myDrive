import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import net.blip.libblip.frontend.State;
public class ContactsCheck {
 static byte[] join(byte[]...values){var out=new ByteArrayOutputStream();for(var value:values)out.writeBytes(value);return out.toByteArray();}
 static byte[] number(long n){var out=new ByteArrayOutputStream();do{int b=(int)(n&127);n>>>=7;out.write(b|(n==0?0:128));}while(n>0);return out.toByteArray();}
 static byte[] field(int tag,byte[] value){return join(number(tag*8+2),number(value.length),value);}
 static byte[] str(int tag,String value){return field(tag,value.getBytes(StandardCharsets.UTF_8));}
 static byte[] scalar(int tag,long value){return join(number(tag*8),number(value));}
 public static void main(String[]args)throws Exception {
  if (!BlipBridge.validDeviceName("Studio Pixel 9") || BlipBridge.validDeviceName("   ") ||
      BlipBridge.validDeviceName("Hidden\nname")) throw new AssertionError("Device label validation failed");
  String user="11111111-1111-4111-8111-111111111111",known="22222222-2222-4222-8222-222222222222",old="33333333-3333-4333-8333-333333333333",id="44444444-4444-4444-8444-444444444444";
  byte[] device=join(str(1,known),str(3,"Studio laptop"));
  byte[] contact=join(str(1,"sender@example.test"),str(2,"Studio tester"),str(8,user),field(7,join(str(1,known),field(2,device))));
  byte[] transfer=join(str(100,id),field(200,join(str(1,user),str(2,old))),scalar(700,1),scalar(800,8),scalar(1100,12345));
  State state=State.ADAPTER.decode(join(field(500,field(1,join(str(1,user),field(2,contact)))),field(600,join(str(1,id),field(2,transfer)))));
  List<Object> devices=BlipBridge.devices(state);
  if(devices.size()!=2)throw new AssertionError("History device omitted");
  boolean named=false,history=false;
  for(Object value:devices){var row=(Map<?,?>)value;if(row.get("name").equals("Studio laptop"))named=true;if(row.get("peer").equals(user+":"+old)&&row.get("contact").equals("sender@example.test")&&Boolean.TRUE.equals(row.get("history")))history=true;}
  if(!named||!history)throw new AssertionError("Sender naming or history identity failed");
  if(((Number)((Map<?,?>)BlipBridge.transfers(state).get(0)).get("progress")).longValue()!=12345)throw new AssertionError("Progress counter mismatch");
  System.out.println("Contact names, historical exact devices and native progress mapping passed");
 }
}
